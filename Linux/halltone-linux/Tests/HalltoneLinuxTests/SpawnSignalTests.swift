import Testing
import Foundation
#if canImport(Glibc)
import Glibc
#endif
@testable import HalltoneLinuxKit

/// Helpers must start with no signals blocked even when launched from a thread that blocks them all
/// (GCD workers do), or SIGTERM never reaches them: avahi-publish-service then outlived
/// `systemctl --user restart halltone` for 90 s and a republish left the old advert running.
@Suite(.serialized, .timeLimit(.minutes(1))) struct SpawnSignalTests {
    /// The `SigBlk:` mask of `pid`, from /proc (nil off Linux).
    static func blockedMask(_ pid: Int32) -> String? {
        guard let status = try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8) else { return nil }
        return status.split(separator: "\n").first { $0.hasPrefix("SigBlk:") }
            .map { $0.dropFirst("SigBlk:".count).trimmingCharacters(in: .whitespaces) }
    }

    @Test func childOfAFullyBlockedThreadStartsUnblockedAndDiesOnSIGTERM() throws {
        guard FileManager.default.fileExists(atPath: "/proc/self/status") else { return }
        final class Out: @unchecked Sendable {   // written by the thread before `done`, read after
            var started: Spawn.Started?
            var threadMaskAfter = sigset_t()
        }
        let out = Out()
        let done = DispatchSemaphore(value: 0)
        let t = Thread {
            var all = sigset_t(); sigfillset(&all)
            pthread_sigmask(SIG_SETMASK, &all, nil)
            out.started = try? Spawn.start("/bin/sleep", ["30"], captureStdout: false, captureStderr: false)
            pthread_sigmask(SIG_SETMASK, nil, &out.threadMaskAfter)
            done.signal()
        }
        t.start()
        #expect(done.wait(timeout: .now() + 10) == .success)
        var threadMaskAfter = out.threadMaskAfter
        let s = try #require(out.started)
        defer { if s.process.isRunning { kill(s.process.processIdentifier, SIGKILL) } }
        #expect(sigismember(&threadMaskAfter, SIGTERM) == 1, "launching thread's own mask was not restored")
        let mask = try #require(Self.blockedMask(s.process.processIdentifier))
        #expect(mask.allSatisfy { $0 == "0" }, "child started with signals blocked: SigBlk \(mask)")
        s.process.terminate()   // SIGTERM, as AvahiAdvertiser.terminate() and systemd send
        let deadline = Date().addingTimeInterval(3)
        while s.process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(!s.process.isRunning, "child ignored SIGTERM")
    }
}
