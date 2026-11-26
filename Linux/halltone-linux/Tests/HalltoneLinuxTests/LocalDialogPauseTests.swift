import Testing
import Foundation
import HalltoneCore
import HalltoneDialog
@testable import HalltoneLinuxKit

private func media(_ fake: FakeMPRIS) -> MediaController {
    MediaController(backend: fake, sleeper: { _ in })
}

/// Counts what reaches it.
private final class CountingSender: RemoteSending {
    var commands: [RemoteCommand] = []
    func send(_ command: RemoteCommand) -> RemoteSendOutcome {
        commands.append(command)
        var o = RemoteSendOutcome(); o.result = command == .pauseForPeer ? .paused : .resumed
        return o
    }
}

private final class VirtualClock { var t = 1000.0 }

@Suite(.timeLimit(.minutes(1))) struct LocalDialogPauseTests {
    // MARK: LocalRemoteSender (MPRIS through the Mac's coordinator rules)

    @Test func pausesAndResumesThroughTheMediaController() {
        let f = FakeMPRIS(); f.add("firefox", .playing)
        let s = LocalRemoteSender(media: media(f))
        #expect(s.send(.pauseForPeer).result == .paused)
        #expect(f.status("firefox") == .paused)
        #expect(s.send(.resumeForPeer).result == .resumed)
        #expect(f.status("firefox") == .playing)
        #expect(f.commands == ["Pause org.mpris.MediaPlayer2.firefox", "Play org.mpris.MediaPlayer2.firefox"])
    }

    @Test func requestIdsDifferAndTheTargetIsNamed() {
        let f = FakeMPRIS(); f.add("firefox", .playing)
        let s = LocalRemoteSender(media: media(f))
        let a = s.send(.pauseForPeer), b = s.send(.resumeForPeer)
        #expect(a.requestID != b.requestID)
        #expect(a.target == "this PC (MPRIS)")
    }

    @Test func nothingPlayingMeansNothingIsPausedOrResumed() {
        let f = FakeMPRIS(); f.add("firefox", .paused)
        let s = LocalRemoteSender(media: media(f))
        #expect(s.send(.pauseForPeer).result == .notPlaying)
        #expect(s.send(.resumeForPeer).result == .resumeSkipped)
        #expect(f.commands.isEmpty)
    }

    @Test func resumeOnlyIfStillOurs() {
        let f = FakeMPRIS(); f.add("firefox", .playing)
        let s = LocalRemoteSender(media: media(f))
        #expect(s.send(.pauseForPeer).result == .paused)
        f.set("firefox", .playing)                      // the user pressed play themselves
        #expect(s.send(.resumeForPeer).result == .resumeSkipped)
        #expect(s.send(.pauseForPeer).result == .paused)
        f.set("firefox", track: "/t/2")                 // ...or skipped the track while paused
        #expect(s.send(.resumeForPeer).result == .resumeSkipped)
        #expect(f.status("firefox") == .paused)
    }

    @Test func noBusMeansFailedNotAHang() {
        let f = FakeMPRIS(); f.failListing = true
        let s = LocalRemoteSender(media: media(f))
        #expect(s.send(.pauseForPeer).result == .failed)
    }

    /// A backend that never answers: `send` must give up after its deadline, not wait forever.
    @Test func aWedgedBackendIsBoundedByTheDeadline() {
        final class Stuck: MPRISBackend {
            func players() throws -> [MPRISPlayer] { Thread.sleep(forTimeInterval: 30); return [] }
            func send(_ command: MPRISCommand, to bus: String) -> Bool { false }
        }
        let s = LocalRemoteSender(media: MediaController(backend: Stuck(), sleeper: { _ in }), deadline: 0.5)
        let t0 = Date()
        let out = s.send(.pauseForPeer)
        #expect(out.result == nil && out.error != nil)
        #expect(Date().timeIntervalSince(t0) < 3)
    }

    // MARK: DialogPauseController with the local target

    private func wait(_ what: String, _ condition: () -> Bool) -> Bool { waitUntil(5, condition) }

    @Test func aDialogPausesTheLocalPlayerAndItsEndResumesIt() throws {
        let f = FakeMPRIS(); f.add("firefox", .playing)
        var timing = DialogPauseTiming(); timing.minDialogMs = 50; timing.resumeDelayMs = 50
        let c = DialogPauseController(timing: timing, client: LocalRemoteSender(media: media(f)), enabled: true, targetName: "local player")
        c.start(); defer { c.stop() }
        c.noteSpeech(msSince: 0)
        c.handle(.started(time: 1, detectedAt: 1))
        // The detector keeps reporting live speech while the dialog lasts.
        var paused = false
        for _ in 0..<100 where !paused { c.noteSpeech(msSince: 0); Thread.sleep(forTimeInterval: 0.02); paused = f.status("firefox") == .paused }
        #expect(paused, "never paused: \(c.statusText())")
        #expect(c.statusText().contains("local player paused"))
        c.handle(.ended(time: 2, detectedAt: 2.2))
        #expect(wait("resumed") { f.status("firefox") == .playing })
        #expect(f.commands == ["Pause org.mpris.MediaPlayer2.firefox", "Play org.mpris.MediaPlayer2.firefox"])
    }

    @Test func aOneLinerDoesNotPause() {
        let f = FakeMPRIS(); f.add("firefox", .playing)
        var timing = DialogPauseTiming(); timing.minDialogMs = 300; timing.resumeDelayMs = 50
        let c = DialogPauseController(timing: timing, client: LocalRemoteSender(media: media(f)), enabled: true)
        c.start(); defer { c.stop() }
        c.noteSpeech(msSince: 0)
        c.handle(.started(time: 1, detectedAt: 1))
        c.handle(.ended(time: 1.2, detectedAt: 1.2))
        Thread.sleep(forTimeInterval: 0.6)
        #expect(f.commands.isEmpty)
    }

    @Test func stoppingWhilePausedResumesThePlayer() {
        let f = FakeMPRIS(); f.add("firefox", .playing)
        var timing = DialogPauseTiming(); timing.minDialogMs = 0
        let c = DialogPauseController(timing: timing, client: LocalRemoteSender(media: media(f)), enabled: true)
        c.start()
        c.noteSpeech(msSince: 0)
        c.handle(.started(time: 1, detectedAt: 1))
        for _ in 0..<100 where f.status("firefox") != .paused { c.noteSpeech(msSince: 0); Thread.sleep(forTimeInterval: 0.02) }
        #expect(f.status("firefox") == .paused)
        c.stop()
        #expect(f.status("firefox") == .playing)
    }

    // MARK: loop guard

    @Test func theLoopGuardTripsAfterTooManyPausesAndResumesStillGoThrough() {
        let inner = CountingSender(), clock = VirtualClock()
        let g = PauseLoopGuard(inner, maxPauses: 4, window: 60, cooldown: 600, clock: { clock.t })
        for _ in 0..<4 {
            #expect(g.send(.pauseForPeer).result == .paused)
            #expect(g.send(.resumeForPeer).result == .resumed)
            clock.t += 5
        }
        #expect(!g.isTripped)
        let fifth = g.send(.pauseForPeer)
        #expect(fifth.result == .disabled && fifth.note != nil)
        #expect(g.isTripped)
        #expect(inner.commands.filter { $0 == .pauseForPeer }.count == 4)     // the fifth never reached the player
        #expect(g.send(.resumeForPeer).result == .resumed)                    // a real pause is never stranded
        // Still blocked a while later (a slow loop must not slip through)...
        clock.t += 120
        #expect(g.send(.pauseForPeer).result == .disabled)
        // ...until the cool-down passes, or the user turns dialog pause off and on.
        clock.t += 600
        #expect(g.send(.pauseForPeer).result == .paused)
    }

    @Test func pausesSpreadOverTheWindowDontTrip() {
        let inner = CountingSender(), clock = VirtualClock()
        let g = PauseLoopGuard(inner, maxPauses: 4, window: 60, clock: { clock.t })
        for _ in 0..<20 {
            #expect(g.send(.pauseForPeer).result == .paused)
            clock.t += 20      // 3 per window at most
        }
        #expect(!g.isTripped)
    }

    @Test func resetClearsATrippedGuard() {
        let clock = VirtualClock()
        let g = PauseLoopGuard(CountingSender(), maxPauses: 1, window: 60, clock: { clock.t })
        _ = g.send(.pauseForPeer)
        #expect(g.send(.pauseForPeer).result == .disabled)
        g.reset()
        #expect(g.send(.pauseForPeer).result == .paused)
    }

    /// The feedback loop itself: the detector "hears" the video exactly while it plays. Without
    /// the guard that is an endless pause/resume cycle; with it, 4 pauses and then the video is left alone.
    @Test func aSimulatedFeedbackLoopIsCutShort() {
        let f = FakeMPRIS(); f.add("firefox", .playing)
        var timing = DialogPauseTiming(); timing.minDialogMs = 0; timing.resumeDelayMs = 0
        let guarded = PauseLoopGuard(LocalRemoteSender(media: media(f)), maxPauses: 4, window: 60)
        let c = DialogPauseController(timing: timing, client: guarded, enabled: true)
        c.start(); defer { c.stop() }
        var hearing = false
        let deadline = Date().addingTimeInterval(8)
        var t = 1.0
        while Date() < deadline {
            let playing = f.status("firefox") == .playing
            c.noteSpeech(msSince: playing ? 0 : 5_000)
            if playing, !hearing { hearing = true; c.handle(.started(time: t, detectedAt: t)) }
            if !playing, hearing { hearing = false; c.handle(.ended(time: t, detectedAt: t)) }
            t += 0.02
            Thread.sleep(forTimeInterval: 0.02)
            if guarded.isTripped { break }
        }
        Thread.sleep(forTimeInterval: 0.5)
        #expect(guarded.isTripped)
        let pauses = f.commands.filter { $0.hasPrefix("Pause") }.count
        #expect(pauses == 4, "\(f.commands)")
        #expect(f.status("firefox") == .playing)                   // the video was left playing
    }

    // MARK: excluded-player mapping

    static let inputs = """
    [
      {"index": 10, "corked": false, "properties": {"application.name": "Firefox", "application.process.binary": "firefox", "media.name": "AudioStream"}},
      {"index": 11, "corked": false, "properties": {"application.name": "Google Chrome", "application.process.binary": "chrome"}},
      {"index": 12, "corked": false, "properties": {"application.name": "Cyberpunk2077.exe", "media.name": "audio stream"}},
      {"index": 13, "corked": false, "properties": {"application.name": "mpv Media Player", "application.process.binary": "mpv"}}
    ]
    """

    @Test func aPlayersStreamsAreMappedFromItsBusNameAndIdentity() {
        let ff = MPRISPlayer(bus: "org.mpris.MediaPlayer2.firefox.instance_1_42", identity: "Mozilla Firefox", status: .playing)
        let cr = MPRISPlayer(bus: "org.mpris.MediaPlayer2.chromium.instance9", identity: "Chromium", status: .playing)
        #expect(PlayerStreamMap.keys(for: ff) == ["firefox", "mozilla firefox"])
        #expect(Set(PlayerStreamMap.keys(for: cr)).isSuperset(of: ["chromium", "chrome"]))
        #expect(PlayerStreamMap.isExcluded(names: ["firefox", "audiostream"], keys: PlayerStreamMap.keys(for: ff)))
        #expect(PlayerStreamMap.isExcluded(names: ["google chrome", "chrome"], keys: PlayerStreamMap.keys(for: cr)))
        #expect(!PlayerStreamMap.isExcluded(names: ["cyberpunk2077.exe"], keys: PlayerStreamMap.keys(for: ff)))
        #expect(!PlayerStreamMap.isExcluded(names: ["firefox"], keys: []))
    }

    @Test func theSinkInputOfTheControlledPlayerIsNeverAnalyzed() {
        let json = Data(Self.inputs.utf8)
        let ff = PlayerStreamMap.keys(for: [MPRISPlayer(bus: "org.mpris.MediaPlayer2.firefox.instance_1_42", identity: "Mozilla Firefox", status: .playing)])
        // The game is found as usual...
        #expect(AppStreamCapture.matchResult(json: json, app: "cyberpunk", excluding: ff)?.index == 12)
        // ...but sourceApp naming the player itself finds nothing, and says why.
        let r = AppStreamCapture.matchResult(json: json, app: "firefox", excluding: ff)
        #expect(r?.index == nil && r?.excluded == true)
        // The Mac target (no exclusion) analyzes it as before.
        #expect(AppStreamCapture.match(json: json, app: "firefox") == 10)
        // An app that is simply not there is not "excluded".
        let none = AppStreamCapture.matchResult(json: json, app: "steam", excluding: ff)
        #expect(none?.index == nil && none?.excluded == false)
    }

    @Test func theMediaControllerExposesTheKeysOfEveryPlayerItMayPause() {
        let f = FakeMPRIS(); f.add("firefox.instance_1_42", .playing, identity: "Mozilla Firefox"); f.add("vlc", .paused); f.add("steam", .paused)
        let m = MediaController(backend: f, ignore: ["steam"], sleeper: { _ in }); m.refresh()
        let keys = m.excludedStreamKeys()
        #expect(keys.contains("firefox") && keys.contains("vlc") && !keys.contains("steam"))
    }

    @Test func listsAudioApps() {
        let apps = AppStreamCapture.sinkInputs(json: Data(Self.inputs.utf8))
        #expect(apps.map(\.index) == [10, 11, 12, 13])
        #expect(apps[2].name == "Cyberpunk2077.exe" && apps[0].binary == "firefox")
    }

    // MARK: config

    func resolve(_ dialog: [String: Any] = [:], _ args: [String] = [], source: String? = nil) throws -> LinuxConfig {
        try LinuxConfig.resolve(file: ["pairingCode": 4321, "dialogPause": dialog],
                                flags: Flags.parse(args + (source.map { ["--source", $0] } ?? [])), hostname: "box")
    }

    @Test func targetDefaultsToTheMac() throws {
        let c = try resolve(["pairingCode": 7777])
        #expect(c.dialogPause.target == .mac && c.dialogPause.isConfigured)
        #expect(!(try resolve()).dialogPause.isConfigured)
    }

    @Test func targetLocalNeedsNoMacCodeButNeedsASourceApp() throws {
        let c = try resolve(["target": "local", "enabled": true, "sourceApp": "Game"])
        #expect(c.dialogPause.target == .local && c.dialogPause.isConfigured && c.dialogPause.pairingCode == nil)
        #expect(c.dialogPause.sourceApp == "Game")
        // Refused with a message that tells the user what to do.
        do { _ = try resolve(["target": "local", "enabled": true]); Issue.record("should have refused") }
        catch { #expect("\(error)".contains("sourceApp") && "\(error)".contains("halltone-linux apps")) }
        // A test source is the game by construction.
        #expect(try resolve(["target": "local", "enabled": true], source: "wav:/tmp/x.wav").dialogPause.target == .local)
        // The flag works too.
        #expect(try resolve([:], ["--dialog-target", "local", "--dialog-app", "Game", "--dialog-pause"]).dialogPause.enabled)
    }

    @Test func targetCanNameAHostOrTheMac() throws {
        let h = try resolve(["target": "mac.local", "pairingCode": 7777])
        #expect(h.dialogPause.target == .mac && h.dialogPause.mac == "mac.local")
        let m = try resolve(["target": "mac", "mac": "10.0.0.5", "pairingCode": 7777])
        #expect(m.dialogPause.target == .mac && m.dialogPause.mac == "10.0.0.5")
        #expect(throws: ConfigError.self) { try self.resolve(["target": "mac", "enabled": true]) }   // still needs the Mac's code
        #expect(throws: ConfigError.self) { try self.resolve(["target": 5.5]) }
    }
}
