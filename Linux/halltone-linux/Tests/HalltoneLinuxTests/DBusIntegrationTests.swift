import Testing
import Foundation
import HalltoneCore
@testable import HalltoneLinuxKit

/// MPRIS over a real D-Bus session bus: a tiny Python/GLib player (Tests/fixtures) on a private
/// bus, driven through `busctl` by `BusctlBackend`, the phone's CONTROL packets and REMOTE_CONTROL
/// packets. Needs `dbus-run-session`, busctl and python3-gi, so CI runs it as
/// `HALLTONE_DBUS_TEST=1 dbus-run-session -- swift test --filter DBusIntegrationTests`; elsewhere
/// it is skipped.
@Suite(.serialized, .timeLimit(.minutes(3)),
       .enabled(if: ProcessInfo.processInfo.environment["HALLTONE_DBUS_TEST"] == "1",
                "set HALLTONE_DBUS_TEST=1 inside dbus-run-session"))
struct DBusIntegrationTests {
    static var fixture: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/fake_mpris_player.py").path
    }

    final class FakePlayer {
        let process = Process()
        init(_ name: String, _ status: String, identity: String? = nil) throws {
            let out = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", DBusIntegrationTests.fixture, name, status] + (identity.map { [$0] } ?? [])
            process.standardOutput = out
            try process.run()
            let line = out.fileHandleForReading.availableData
            guard String(decoding: line, as: UTF8.self).contains("ready") else {
                throw ConfigError("fake MPRIS player \(name) didn't start")
            }
        }
        func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    }

    static func status(_ backend: BusctlBackend, _ name: String) -> MPRISStatus? {
        ((try? backend.players()) ?? []).first { $0.bus == MPRISNames.prefix + name }?.status
    }

    @Test func busctlBackendListsAndDrivesAPlayer() throws {
        let p = try FakePlayer("fakea", "Playing", identity: "Fake A"); defer { p.stop() }
        let backend = BusctlBackend()
        let list = try backend.players()
        let a = try #require(list.first { $0.shortName == "fakea" })
        #expect(a.status == .playing)
        #expect(a.identity == "Fake A")
        #expect(a.trackID == "/fake/track/1")
        #expect(a.title == "Track 1")
        #expect(backend.send(.pause, to: a.bus))
        #expect(Self.status(backend, "fakea") == .paused)
        #expect(backend.send(.next, to: a.bus))
        #expect(try backend.players().first { $0.shortName == "fakea" }?.trackID == "/fake/track/2")
        #expect(!backend.send(.play, to: "org.mpris.MediaPlayer2.nothere"))
    }

    @Test func pickingPinAndIgnoreOnTheRealBus() throws {
        let a = try FakePlayer("fakea", "Playing"); defer { a.stop() }
        let b = try FakePlayer("fakeb", "Paused"); defer { b.stop() }
        #expect(MediaController(pin: nil).refresh())
        let m = MediaController()
        m.refresh()
        #expect(m.chosen()?.shortName == "fakea")                       // the playing one
        let pinned = MediaController(pin: "fakeb"); pinned.refresh()
        #expect(pinned.chosen()?.shortName == "fakeb")
        let ignoring = MediaController(ignore: ["fakea"]); ignoring.refresh()
        #expect(ignoring.chosen()?.shortName == "fakeb")
        #expect(ignoring.perform(.play))
        #expect(Self.status(BusctlBackend(), "fakeb") == .playing)
        #expect(Self.status(BusctlBackend(), "fakea") == .playing)      // untouched
    }

    @Test func phoneControlsAndRemoteControlThroughTheRealBus() throws {
        let p = try FakePlayer("fakea", "Playing"); defer { p.stop() }
        let backend = BusctlBackend()
        let media = MediaController(backend: backend)
        media.startPolling(interval: 0.2); defer { media.stopPolling() }
        let h = try MediaSenderHarness(media: media)

        #expect(h.waitForStatus { $0.contains(.controlsAvailable) && $0.contains(.macPlaying) })
        h.control(.pause)
        #expect(waitUntil { Self.status(backend, "fakea") == .paused })
        #expect(h.waitForStatus { !$0.contains(.macPlaying) })
        h.control(.play)
        #expect(waitUntil { Self.status(backend, "fakea") == .playing })
        h.control(.next)
        #expect(waitUntil { ((try? backend.players()) ?? []).first?.trackID == "/fake/track/2" })

        // REMOTE_CONTROL, as halltone-cli sends it.
        #expect(h.remote(.pauseForPeer) == .paused)
        #expect(Self.status(backend, "fakea") == .paused)
        #expect(h.remote(.resumeForPeer) == .resumed)
        #expect(Self.status(backend, "fakea") == .playing)
        #expect(h.remote(.pauseForPeer) == .paused)
        #expect(backend.send(.play, to: MPRISNames.prefix + "fakea"))   // the user resumed by hand
        #expect(h.remote(.resumeForPeer) == .resumeSkipped)
        #expect(h.remote(.pauseForPeer) == .paused)
        #expect(backend.send(.next, to: MPRISNames.prefix + "fakea"))   // ...or skipped the track
        #expect(h.remote(.resumeForPeer) == .resumeSkipped)
        #expect(Self.status(backend, "fakea") == .paused)
    }

    @Test func playersAndMediaSubcommands() throws {
        let p = try FakePlayer("fakea", "Playing", identity: "Fake A"); defer { p.stop() }
        let q = try FakePlayer("fakeb", "Paused"); defer { q.stop() }
        var r = try Self.cli(["players"])
        #expect(r.status == 0 && r.output.contains("fakea") && r.output.contains("fakeb") && r.output.contains("<- controlled"), "\(r)")
        r = try Self.cli(["players", "--media-ignore", "fakea"])
        #expect(r.output.contains("(ignored)"), "\(r)")
        r = try Self.cli(["media", "status"])
        #expect(r.status == 0 && r.output.contains("playing: fakea"), "\(r)")
        r = try Self.cli(["media", "pause"])
        #expect(r.status == 0 && r.output.contains("ok: pause"), "\(r)")
        r = try Self.cli(["media", "status"])
        #expect(r.output.contains("paused: fakea"), "\(r)")
        r = try Self.cli(["media", "play", "--media-player", "fakeb"])
        #expect(r.status == 0, "\(r)")
        #expect(Self.status(BusctlBackend(), "fakeb") == .playing)
        r = try Self.cli(["media", "dance"])
        #expect(r.status == 2, "\(r)")
    }

    static func cli(_ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = IntegrationTests.binary
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
