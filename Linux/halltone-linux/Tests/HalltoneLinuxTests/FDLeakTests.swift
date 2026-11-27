import Testing
import Foundation
@testable import HalltoneLinuxKit

/// Regression tests for #25: 0.1.0 leaked two pipe descriptors per `busctl` call (about one call a
/// second) until the process hit 1024 open files and capture and Avahi failed. They count
/// `/proc/self/fd` (`/dev/fd` on a Mac). The leak was ~2 per call, so 300
/// calls would grow the count by ~600; a bound of 25 absorbs other suites running at the same time.
func openFDs() -> Int? {
    for dir in ["/proc/self/fd", "/dev/fd"] {   // /dev/fd lets the same test run on a Mac
        if let n = try? FileManager.default.contentsOfDirectory(atPath: dir).count { return n }
    }
    return nil
}

/// Lets reader threads and termination handlers finish, then reports the count.
func settledFDs() -> Int? {
    var last = openFDs()
    for _ in 0..<20 {
        Thread.sleep(forTimeInterval: 0.1)
        let now = openFDs()
        if now == last { break }
        last = now
    }
    return last
}

private func writeScript(_ body: String) throws -> (dir: String, path: String) {
    let dir = NSTemporaryDirectory() + "halltone-fd-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/busctl"
    try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return (dir, path)
}

/// A busctl that answers `list`, `GetAll` and `Identity` like a session bus with one playing player.
private let fakeBusctl = """
case "$*" in
  *" list"*) echo "org.mpris.MediaPlayer2.fake 123 fake :1.5 user 1 session - -" ;;
  *GetAll*) echo '{"type":"a{sv}","data":[{"PlaybackStatus":{"type":"s","data":"Playing"},"Metadata":{"type":"a{sv}","data":{"mpris:trackid":{"type":"o","data":"/t/1"},"xesam:title":{"type":"s","data":"Song"}}}}]}' ;;
  *Identity*) echo '{"type":"s","data":"Fake"}' ;;
esac
"""

@Suite(.serialized, .timeLimit(.minutes(3))) struct FDLeakTests {
    private let slack = 25
    private let calls = 300

    @Test func commandRunnerClosesItsPipesOnEveryPath() throws {
        guard openFDs() != nil else { return }   // not Linux
        // Warm up lazily created descriptors (thread pools, /dev/null), then measure.
        _ = CommandRunner.run("/bin/echo", ["warm"], timeout: 5)
        let before = try #require(settledFDs())
        for _ in 0..<calls {
            #expect(CommandRunner.run("/bin/echo", ["ok"], timeout: 5)?.status == 0)               // success
            #expect(CommandRunner.run("/bin/sh", ["-c", "echo err 1>&2; exit 3"], timeout: 5)?.status == 3) // non-zero exit
        }
        for _ in 0..<30 { #expect(CommandRunner.run("/bin/sleep", ["30"], timeout: 0.05) == nil) }  // timeout
        for _ in 0..<calls { #expect(CommandRunner.run("/nonexistent/program", [], timeout: 1) == nil) } // can't launch
        let after = try #require(settledFDs())
        print("FDCOUNT commandRunner before=\(before) after=\(after)")
        #expect(after - before <= slack, "fd count grew from \(before) to \(after)")
    }

    @Test func busctlBackendDoesNotLeakAcrossRefreshes() throws {
        guard openFDs() != nil else { return }
        let (dir, path) = try writeScript(fakeBusctl)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let m = MediaController(backend: BusctlBackend(executable: path, timeout: 5))
        #expect(m.refresh())
        #expect(m.peekPlaying() == true)   // the fake bus really answers, so the loop below spawns for real
        let before = try #require(settledFDs())
        for _ in 0..<calls { #expect(m.refresh()) }
        let after = try #require(settledFDs())
        print("FDCOUNT busctlBackend before=\(before) after=\(after) refreshes=\(calls)")
        #expect(after - before <= slack, "fd count grew from \(before) to \(after) over \(calls) refreshes")
    }

    @Test func anIdleSenderDoesNotPollTheBus() throws {
        let f = FakeMPRIS(); f.add("mpv", .playing)
        let counter = CountingBackend(f)
        let m = MediaController(backend: counter)
        m.startPolling(interval: 0.05); defer { m.stopPolling() }
        Thread.sleep(forTimeInterval: 0.6)
        #expect(counter.calls == 0, "polled \(counter.calls) times with nobody asking")
        #expect(m.peekPlaying() == true)   // asking refreshes once and starts the background poll
        let afterAsk = counter.calls
        #expect(afterAsk >= 1)
        Thread.sleep(forTimeInterval: 0.4)
        #expect(counter.calls > afterAsk, "the poll should run while someone is asking")
    }
}

private final class CountingBackend: MPRISBackend {
    private let inner: MPRISBackend
    private let lock = NSLock()
    private var n = 0
    init(_ inner: MPRISBackend) { self.inner = inner }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return n }
    func players() throws -> [MPRISPlayer] { lock.lock(); n += 1; lock.unlock(); return try inner.players() }
    func send(_ command: MPRISCommand, to bus: String) -> Bool { inner.send(command, to: bus) }
}
