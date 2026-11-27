import Testing
import Foundation
#if canImport(Glibc)
import Glibc
#endif
import HalltoneCore
import HalltoneSenderCore
@testable import HalltoneLinuxKit

final class FakePresenceBackend: PresenceBackend {
    private let lock = NSLock()
    private var s: PresenceSample
    private var n = 0
    var delay: TimeInterval = 0
    init(_ s: PresenceSample = PresenceSample()) { self.s = s }
    var value: PresenceSample { get { lock.lock(); defer { lock.unlock() }; return s } set { lock.lock(); s = newValue; lock.unlock() } }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return n }
    func sample() -> PresenceSample {
        lock.lock(); n += 1; let v = s; let d = delay; lock.unlock()
        if d > 0 { Thread.sleep(forTimeInterval: d) }
        return v
    }
}

struct PresenceRulesTests {
    @Test func activeSetsBothFlags() {
        let p = Presence(PresenceSample(idleSeconds: 2, locked: false))
        #expect(p == Presence(inputRecent: true, atPC: true))
    }
    @Test func idleOver20ClearsRecentInputButNotAtPC() {
        let p = Presence(PresenceSample(idleSeconds: 60, locked: false))
        #expect(p == Presence(inputRecent: false, atPC: true))
    }
    @Test func idleOver180ClearsBoth() {
        #expect(Presence(PresenceSample(idleSeconds: 181, locked: false)) == Presence(inputRecent: false, atPC: false))
    }
    @Test func lockedClearsBothEvenWithFreshInput() {
        #expect(Presence(PresenceSample(idleSeconds: 1, locked: true)) == Presence(inputRecent: false, atPC: false))
    }
    @Test func lockUnknownButRecentInputStillCountsAsAtPC() {
        #expect(Presence(PresenceSample(idleSeconds: 1, locked: nil)) == Presence(inputRecent: true, atPC: true))
    }
    @Test func logindFallbackOnly() {
        #expect(Presence(PresenceSample(locked: false, sessionIdle: false)) == Presence(inputRecent: nil, atPC: true))
        #expect(Presence(PresenceSample(locked: false, sessionIdle: true)) == Presence(inputRecent: nil, atPC: false))
        #expect(Presence(PresenceSample(sessionIdle: false)) == Presence())   // lock unknown: unknown, not "at"
    }
    @Test func nothingAvailableIsUnknownNotAway() {
        #expect(Presence(PresenceSample()) == Presence(inputRecent: nil, atPC: nil))
    }
    @Test func parsesBusctlReplies() {
        #expect(BusctlPresenceBackend.number("t 12345\n") == 12345)
        #expect(BusctlPresenceBackend.number("s \"x\"\n") == nil)
        #expect(BusctlPresenceBackend.bool("b true\n") == true)
        #expect(BusctlPresenceBackend.bool("b false\n") == false)
        #expect(BusctlPresenceBackend.bool("") == nil)
    }
}

final class TestClock {
    private let lock = NSLock(); private var t = 1000.0
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ d: TimeInterval) { lock.lock(); t += d; lock.unlock() }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct PresenceMonitorTests {
    private func waitFor(_ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return cond()
    }

    @Test func activeThenIdleThenLocked() {
        let b = FakePresenceBackend(PresenceSample(idleSeconds: 1, locked: false))
        let clock = TestClock()
        let m = PresenceMonitor(backend: b, interval: 3, clock: { clock.now })
        #expect(m.current() == Presence())   // first read never waits: unknown until the sample lands
        #expect(waitFor { m.current().atPC == true })
        #expect(m.userAtPC() && m.inputRecent())

        b.value = PresenceSample(idleSeconds: 30, locked: false); clock.advance(4)
        #expect(waitFor { m.current() == Presence(inputRecent: false, atPC: true) })
        #expect(m.userAtPC() && !m.inputRecent())

        b.value = PresenceSample(idleSeconds: 300, locked: false); clock.advance(4)
        #expect(waitFor { !m.userAtPC() && m.current().atPC == false })

        b.value = PresenceSample(idleSeconds: 1, locked: true); clock.advance(4)
        #expect(waitFor { m.current() == Presence(inputRecent: false, atPC: false) })
    }

    @Test func missingBackendIsUnknownAndReportsNoFlags() {
        let b = FakePresenceBackend(PresenceSample())
        let m = PresenceMonitor(backend: b)
        #expect(waitFor { _ = m.current(); return b.calls >= 1 })
        Thread.sleep(forTimeInterval: 0.05)
        #expect(m.current() == Presence(inputRecent: nil, atPC: nil))
        #expect(!m.userAtPC() && !m.inputRecent())
    }

    @Test func staleSampleReadsAsUnknown() {
        let b = FakePresenceBackend(PresenceSample(idleSeconds: 1, locked: false))
        let clock = TestClock()
        var want = true
        let m = PresenceMonitor(backend: b, interval: 3, maxAge: 12, wanted: { want }, clock: { clock.now })
        m.refreshNow()
        #expect(m.userAtPC())
        want = false; clock.advance(60)   // nobody listening: no refresh, and the old answer is not trusted
        #expect(m.current() == Presence())
        #expect(b.calls == 1)
    }

    @Test func readsAreCachedAndNeverBlockOnASlowBackend() {
        let b = FakePresenceBackend(PresenceSample(idleSeconds: 1, locked: false))
        b.delay = 1.0
        let clock = TestClock()
        let m = PresenceMonitor(backend: b, interval: 3, clock: { clock.now })
        let t0 = Date()
        for _ in 0..<10_000 { _ = m.current() }
        #expect(Date().timeIntervalSince(t0) < 0.5, "reads waited for the backend")
        #expect(waitFor { b.calls == 1 })
        Thread.sleep(forTimeInterval: 1.2)
        for _ in 0..<10_000 { _ = m.current() }
        #expect(b.calls == 1, "\(b.calls) samples inside one interval")
    }

    @Test func sendsNothingWhenNobodyIsListening() {
        let b = FakePresenceBackend(PresenceSample(idleSeconds: 1, locked: false))
        let m = PresenceMonitor(backend: b, interval: 0.01, wanted: { false })
        for _ in 0..<100 { _ = m.current(); Thread.sleep(forTimeInterval: 0.005) }
        #expect(b.calls == 0)
    }

    @Test func senderStatusCarriesTheFlags() {
        let b = FakePresenceBackend(PresenceSample(idleSeconds: 1, locked: false))
        let m = PresenceMonitor(backend: b)
        m.refreshNow()
        let s = LinuxSender(config: SenderCore.Config(), media: nil, presence: m, allowRemoteControl: false) { ToneSource(amplitude: 0) }
        #expect(s.userAtMac?() == true && s.userInputRecent?() == true)
        b.value = PresenceSample(idleSeconds: 1, locked: true); m.refreshNow()
        #expect(s.userAtMac?() == false && s.userInputRecent?() == false)
    }
}

/// The lesson of 0.1.0: a helper spawned about once a second must not leak descriptors. These
/// drive the real busctl backend (with a fake `busctl`) the way the monitor does.
@Suite(.serialized, .timeLimit(.minutes(3))) struct PresenceFDTests {
    private func fakeBusctl() throws -> (dir: String, path: String) {
        let dir = NSTemporaryDirectory() + "halltone-presence-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/busctl"
        let body = """
        #!/bin/sh
        case "$*" in
          *GetIdletime*) echo "t 2000" ;;
          *GetActive*) echo "b false" ;;
          *) echo "b false" ;;
        esac
        """
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (dir, path)
    }

    @Test func fakeBusctlIsUnderstood() throws {
        let (dir, path) = try fakeBusctl(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = Presence(BusctlPresenceBackend(executable: path, timeout: 5).sample())
        #expect(p == Presence(inputRecent: true, atPC: true))
    }

    @Test func monitorDoesNotLeakDescriptorsAcrossManyRefreshes() throws {
        guard openFDs() != nil else { return }
        let (dir, path) = try fakeBusctl(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let m = PresenceMonitor(backend: BusctlPresenceBackend(executable: path, timeout: 5), interval: 0.0)
        #expect(m.refreshNow().atPC == true)
        let before = try #require(settledFDs())
        for _ in 0..<150 { m.refreshNow() }            // 2 spawns each
        for _ in 0..<150 { _ = m.current(); Thread.sleep(forTimeInterval: 0.002) }   // the background path
        let after = try #require(settledFDs())
        print("FDCOUNT presence before=\(before) after=\(after)")
        #expect(after - before <= 25, "fd count grew from \(before) to \(after)")
    }

    @Test func missingAndHungBusctlDoNotLeakOrStall() throws {
        guard openFDs() != nil else { return }
        let missing = BusctlPresenceBackend(executable: "/nonexistent/busctl", timeout: 1)
        #expect(Presence(missing.sample()) == Presence())
        let before = try #require(settledFDs())
        for _ in 0..<100 { _ = missing.sample() }
        // A busctl that never answers is cut off at the timeout, and the sample is "unknown".
        let hung = BusctlPresenceBackend(executable: "/bin/sleep", timeout: 0.1)   // sleep rejects its args and exits non-zero
        for _ in 0..<20 { #expect(Presence(hung.sample()) == Presence()) }
        let after = try #require(settledFDs())
        #expect(after - before <= 25, "fd count grew from \(before) to \(after)")
    }
}

/// Against a fake `org.gnome.Mutter.IdleMonitor` / `org.gnome.ScreenSaver` on a private session bus.
/// CI runs it as `HALLTONE_DBUS_TEST=1 dbus-run-session -- swift test --filter PresenceDBusTests`.
@Suite(.serialized, .timeLimit(.minutes(1)),
       .enabled(if: ProcessInfo.processInfo.environment["HALLTONE_DBUS_TEST"] == "1",
                "set HALLTONE_DBUS_TEST=1 inside dbus-run-session"))
struct PresenceDBusTests {
    static var fixture: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/fake_gnome_presence.py").path
    }

    final class FakeGnome {
        let process = Process()
        let state = NSTemporaryDirectory() + "halltone-gnome-\(UUID().uuidString)"
        init() throws {
            set(idleMs: 0, locked: false)
            let out = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", PresenceDBusTests.fixture, state]
            process.standardOutput = out
            try process.run()
            let ready = DispatchSemaphore(value: 0)
            let lock = NSLock(); var text = ""
            Thread.detachNewThread {
                while true {
                    let d = out.fileHandleForReading.availableData
                    if d.isEmpty { break }
                    lock.lock(); text += String(decoding: d, as: UTF8.self); let ok = text.contains("ready"); lock.unlock()
                    if ok { ready.signal() }
                }
            }
            guard ready.wait(timeout: .now() + 20) == .success else {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw ConfigError("fake GNOME presence service not ready after 20 s")
            }
        }
        func set(idleMs: Int, locked: Bool) {
            try? "\(idleMs)\n\(locked ? "locked" : "unlocked")\n".write(toFile: state, atomically: true, encoding: .utf8)
        }
        func stop() {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(atPath: state)
        }
    }

    @Test func busctlBackendReadsIdleAndLockFromTheBus() throws {
        let g = try FakeGnome(); defer { g.stop() }
        let b = BusctlPresenceBackend()
        g.set(idleMs: 1500, locked: false)
        #expect(Presence(b.sample()) == Presence(inputRecent: true, atPC: true))
        g.set(idleMs: 45_000, locked: false)
        #expect(Presence(b.sample()) == Presence(inputRecent: false, atPC: true))
        g.set(idleMs: 400_000, locked: false)
        #expect(Presence(b.sample()) == Presence(inputRecent: false, atPC: false))
        g.set(idleMs: 500, locked: true)
        #expect(Presence(b.sample()) == Presence(inputRecent: false, atPC: false))
    }

    @Test func statusFlagsFollowTheDesktop() throws {
        let g = try FakeGnome(); defer { g.stop() }
        let m = PresenceMonitor(interval: 0.1, wanted: { true })
        let sender = LinuxSender(config: SenderCore.Config(), media: nil, presence: m, allowRemoteControl: false) { ToneSource(amplitude: 0) }
        func wait(_ cond: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(10)
            while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.05) }
            return cond()
        }
        g.set(idleMs: 800, locked: false)
        #expect(wait { sender.userAtMac?() == true && sender.userInputRecent?() == true })
        g.set(idleMs: 60_000, locked: false)
        #expect(wait { sender.userAtMac?() == true && sender.userInputRecent?() == false })
        g.set(idleMs: 800, locked: true)
        #expect(wait { sender.userAtMac?() == false && sender.userInputRecent?() == false })
    }

    @Test func noGnomeOnTheBusMeansUnknown() throws {
        // The fake isn't started: the bus has no IdleMonitor, so the answer is unknown (logind may
        // answer on a real machine; in CI there is no system bus, so it is nothing at all).
        let p = Presence(BusctlPresenceBackend(timeout: 3).sample())
        #expect(p.inputRecent == nil)
    }
}
