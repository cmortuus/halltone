import Testing
import Foundation
import HalltoneCore
@testable import HalltoneLinuxKit

/// A controller on a virtual clock, so "most recently started" and the pause wait are exact.
private final class Clock {
    var t: TimeInterval = 100
}
private func make(_ fake: FakeMPRIS, pin: String? = nil, ignore: [String] = [], clock: Clock = Clock()) -> MediaController {
    MediaController(backend: fake, pin: pin, ignore: ignore, clock: { clock.t }, sleeper: { clock.t += $0 })
}

@Suite struct MediaControllerTests {
    // MARK: choosing

    @Test func prefersThePlayingPlayer() {
        let f = FakeMPRIS(); f.add("mpv", .paused); f.add("firefox", .playing)
        let m = make(f); m.refresh()
        #expect(m.chosen()?.shortName == "firefox")
    }

    @Test func severalPlayingPrefersTheMostRecentlyStarted() {
        let f = FakeMPRIS(); let clock = Clock()
        f.add("firefox", .playing); f.add("spotify", .paused)
        let m = make(f, clock: clock); m.refresh()
        clock.t += 10; f.set("spotify", .playing); m.refresh()
        #expect(m.chosen()?.shortName == "spotify")
        // Pausing and restarting firefox makes it the newest.
        clock.t += 10; f.set("firefox", .paused); m.refresh()
        clock.t += 10; f.set("firefox", .playing); m.refresh()
        #expect(m.chosen()?.shortName == "firefox")
    }

    @Test func nothingPlayingUsesTheLastPlayerWeUsedThenTheFirst() {
        let f = FakeMPRIS(); f.add("mpv", .paused); f.add("vlc", .paused)
        let m = make(f); m.refresh()
        #expect(m.chosen()?.shortName == "mpv")
        #expect(m.perform(.play))               // chooses mpv, remembers it
        f.set("mpv", .paused); f.set("vlc", .paused)
        #expect(m.perform(.next))
        #expect(m.chosen()?.shortName == "mpv")
    }

    @Test func pinSelectsBySubstringOfNameOrIdentity() {
        let f = FakeMPRIS(); f.add("firefox.instance_1_5", .paused, identity: "Mozilla Firefox"); f.add("mpv", .playing, identity: "mpv Media Player")
        let byName = make(f, pin: "FIREFOX"); byName.refresh()
        #expect(byName.chosen()?.shortName == "firefox.instance_1_5") // even though mpv is the one playing
        let byIdentity = make(f, pin: "media player"); byIdentity.refresh()
        #expect(byIdentity.chosen()?.shortName == "mpv")
        let none = make(f, pin: "spotify"); none.refresh()
        #expect(none.chosen() == nil)
        #expect(none.controlsAvailable() == false)
    }

    @Test func ignoredPlayersAreNeverChosenOrTouched() {
        let f = FakeMPRIS(); f.add("steam", .playing, identity: "Steam Game"); f.add("firefox", .paused)
        let m = make(f, ignore: ["steam"]); m.refresh()
        #expect(m.chosen()?.shortName == "firefox")
        #expect(m.peekPlaying() == false)
        #expect(m.perform(.pause))
        #expect(!f.commands.contains { $0.contains("steam") })
        let onlyIgnored = FakeMPRIS(); onlyIgnored.add("steam", .playing)
        let m2 = make(onlyIgnored, ignore: ["Steam"]); m2.refresh()
        #expect(m2.controlsAvailable() == false)
        #expect(m2.peekPlaying() == nil)
        #expect(m2.perform(.play) == false)
        #expect(onlyIgnored.commands.isEmpty)
    }

    @Test func listingMarksIgnoredAndChosen() {
        let f = FakeMPRIS(); f.add("steam", .playing); f.add("firefox", .playing)
        let m = make(f, ignore: ["steam"])
        let e = m.listing() ?? []
        #expect(e.map { $0.player.shortName } == ["firefox", "steam"])
        #expect(e.first { $0.player.shortName == "steam" }?.ignored == true)
        #expect(e.first { $0.player.shortName == "firefox" }?.chosen == true)
    }

    // MARK: phone commands

    @Test func commandsAreExplicitNeverBlindToggles() {
        let f = FakeMPRIS(); f.add("firefox", .playing)
        let m = make(f)
        #expect(m.perform(.play))      // already playing: nothing sent
        #expect(f.commands.isEmpty)
        #expect(m.perform(.pause))
        #expect(f.status("firefox") == .paused)
        #expect(m.perform(.pause))     // already paused: nothing more
        #expect(f.commands == ["Pause org.mpris.MediaPlayer2.firefox"])
        #expect(m.perform(.playPause)) // reads the state: Paused -> Play
        #expect(f.status("firefox") == .playing)
        #expect(m.perform(.playPause))
        #expect(f.status("firefox") == .paused)
        #expect(m.perform(.next)); #expect(m.perform(.previous))
        #expect(f.commands.suffix(2) == ["Next org.mpris.MediaPlayer2.firefox", "Previous org.mpris.MediaPlayer2.firefox"])
    }

    @Test func noPlayersOrNoBusMeansFailure() {
        let f = FakeMPRIS()
        let m = make(f)
        #expect(m.perform(.pause) == false)
        #expect(m.controlsAvailable() == false)
        f.add("mpv", .playing); f.failListing = true
        #expect(m.perform(.pause) == false)
    }

    // MARK: remote-control environment

    @Test func playbackStateReflectsMPRIS() {
        let f = FakeMPRIS(); let m = make(f)
        #expect(m.playbackState() == .notPlaying)            // no players
        f.add("firefox", .playing)
        #expect(m.playbackState() == .playing)
        f.failListing = true
        #expect(m.playbackState() == .unknown)
    }

    @Test func pauseThatDoesNotTakeIsNotReportedAsPaused() {
        let f = FakeMPRIS(); f.add("firefox", .playing); f.ignoresPause = true
        let m = make(f)
        #expect(m.pausePlayback() == nil)
        #expect(f.status("firefox") == .playing)
    }

    @Test func stillPausedTracksStatusAndTrack() throws {
        let f = FakeMPRIS(); f.add("firefox", .playing)
        let m = make(f)
        let token = try #require(m.pausePlayback())
        #expect(m.isStillPaused(token: token))
        f.set("firefox", track: "/t/2")                       // the track changed
        #expect(!m.isStillPaused(token: token))
        f.set("firefox", track: "/t/1")
        #expect(m.isStillPaused(token: token))
        f.set("firefox", .playing)                            // the user pressed play
        #expect(!m.isStillPaused(token: token))
        f.set("firefox", .stopped)
        #expect(!m.isStillPaused(token: token))
        f.all = []                                        // the player closed
        #expect(!m.isStillPaused(token: token))
        #expect(!m.resumePlayback(token: token))
    }

    // MARK: busctl output

    @Test func parsesBusctlGetAllJSON() throws {
        let json = #"{"type":"a{sv}","data":[{"PlaybackStatus":{"type":"s","data":"Playing"},"Metadata":{"type":"a{sv}","data":{"mpris:trackid":{"type":"o","data":"/org/mpris/MediaPlayer2/firefox"},"xesam:title":{"type":"s","data":"Cats"},"xesam:artist":{"type":"as","data":["x"]}}},"Rate":{"type":"d","data":1}}]}"#
        let p = try #require(BusctlBackend.properties(fromJSON: json))
        #expect(p.status == .playing)
        #expect(p.trackID == "/org/mpris/MediaPlayer2/firefox")
        #expect(p.title == "Cats")
        #expect(BusctlBackend.properties(fromJSON: "garbage") == nil)
        #expect(BusctlBackend.properties(fromJSON: #"{"type":"a{sv}","data":[{"PlaybackStatus":{"type":"s","data":"Paused"}}]}"#)?.status == .paused)
    }
}

// MARK: - The coordinator on top of MPRIS

private final class Rig {
    let fake = FakeMPRIS()
    let clock = Clock()
    let media: MediaController
    let coordinator: RemoteControlCoordinator
    init() {
        let c = clock
        media = MediaController(backend: fake, clock: { c.t }, sleeper: { c.t += $0 })
        coordinator = RemoteControlCoordinator(environment: media)
    }
    func handle(_ cmd: RemoteCommand, peer: String = "Mac", id: UInt32, enabled: Bool = true) -> RemoteResult {
        coordinator.handle(cmd, peer: peer, requestID: id, enabled: enabled)
    }
}

@Suite struct MPRISRemoteControlTests {
    @Test func pausesOnlyWhatIsPlaying() {
        let r = Rig(); r.fake.add("firefox", .playing)
        #expect(r.handle(.pauseForPeer, id: 1) == .paused)
        #expect(r.fake.status("firefox") == .paused)
        #expect(r.coordinator.pausedForPeer == "Mac")
        let idle = Rig(); idle.fake.add("firefox", .paused)
        #expect(idle.handle(.pauseForPeer, id: 1) == .notPlaying)
        #expect(idle.fake.commands.isEmpty)
        #expect(idle.coordinator.pausedForPeer == nil)
        #expect(Rig().handle(.pauseForPeer, id: 1) == .notPlaying)   // no player at all
    }

    @Test func resumesOurPauseWithExplicitPlay() {
        let r = Rig(); r.fake.add("firefox", .playing)
        #expect(r.handle(.pauseForPeer, id: 1) == .paused)
        #expect(r.handle(.resumeForPeer, id: 2) == .resumed)
        #expect(r.fake.status("firefox") == .playing)
        #expect(r.fake.commands == ["Pause org.mpris.MediaPlayer2.firefox", "Play org.mpris.MediaPlayer2.firefox"])
        #expect(r.coordinator.pausedForPeer == nil)
    }

    @Test func doesNotResumeWhatTheUserAlreadyResumedOrChanged() {
        let byHand = Rig(); byHand.fake.add("firefox", .playing)
        _ = byHand.handle(.pauseForPeer, id: 1)
        byHand.fake.set("firefox", .playing)
        #expect(byHand.handle(.resumeForPeer, id: 2) == .resumeSkipped)
        #expect(byHand.fake.commands.count == 1)          // no extra Play
        #expect(byHand.coordinator.pausedForPeer == nil)

        let newTrack = Rig(); newTrack.fake.add("firefox", .playing)
        _ = newTrack.handle(.pauseForPeer, id: 1)
        newTrack.fake.set("firefox", track: "/t/9")
        #expect(newTrack.handle(.resumeForPeer, id: 2) == .resumeSkipped)
        #expect(newTrack.fake.status("firefox") == .paused)
    }

    @Test func resumeNeedsTheSamePeerAndASkippedResumeWithoutAPause() {
        let r = Rig(); r.fake.add("firefox", .playing)
        #expect(r.handle(.resumeForPeer, id: 1) == .resumeSkipped)
        _ = r.handle(.pauseForPeer, peer: "A", id: 2)
        #expect(r.handle(.resumeForPeer, peer: "B", id: 3) == .resumeSkipped)
        #expect(r.fake.status("firefox") == .paused)
        #expect(r.handle(.resumeForPeer, peer: "A", id: 4) == .resumed)
    }

    @Test func pauseExpiresAfterTenMinutesButRenews() {
        let r = Rig(); r.fake.add("firefox", .playing)
        _ = r.handle(.pauseForPeer, id: 1)
        r.clock.t += 500
        #expect(r.handle(.pauseForPeer, id: 2) == .paused)   // renews, no second Pause
        r.clock.t += 500
        #expect(r.handle(.resumeForPeer, id: 3) == .resumed)
        let stale = Rig(); stale.fake.add("firefox", .playing)
        _ = stale.handle(.pauseForPeer, id: 1)
        stale.clock.t += 601
        #expect(stale.handle(.resumeForPeer, id: 2) == .resumeSkipped)
        #expect(stale.fake.status("firefox") == .paused)
    }

    @Test func retriedRequestIDGetsTheSameAnswerWithoutActingTwice() {
        let r = Rig(); r.fake.add("firefox", .playing)
        #expect(r.handle(.pauseForPeer, id: 7) == .paused)
        #expect(r.handle(.pauseForPeer, id: 7) == .paused)
        #expect(r.fake.commands.count == 1)
        #expect(r.handle(.resumeForPeer, id: 8) == .resumed)
        #expect(r.handle(.resumeForPeer, id: 8) == .resumed)
        #expect(r.fake.commands.count == 2)
    }

    @Test func disabledAnswersDisabledAndTouchesNothing() {
        let r = Rig(); r.fake.add("firefox", .playing)
        #expect(r.handle(.pauseForPeer, id: 1, enabled: false) == .disabled)
        #expect(r.fake.commands.isEmpty)
    }

    @Test func failuresAreFailedAndRetryable() {
        let noBus = Rig(); noBus.fake.add("firefox", .playing); noBus.fake.failListing = true
        #expect(noBus.handle(.pauseForPeer, id: 1) == .failed)
        let stuck = Rig(); stuck.fake.add("firefox", .playing); stuck.fake.ignoresPause = true
        #expect(stuck.handle(.pauseForPeer, id: 1) == .failed)
        #expect(stuck.coordinator.pausedForPeer == nil)
        stuck.fake.ignoresPause = false
        #expect(stuck.handle(.pauseForPeer, id: 2) == .paused)  // failed answers aren't cached
    }

    @Test func refreshDropsAPauseTheUserUndid() {
        let r = Rig(); r.fake.add("firefox", .playing)
        _ = r.handle(.pauseForPeer, id: 1)
        r.fake.set("firefox", .playing)
        r.coordinator.refresh()
        #expect(r.coordinator.pausedForPeer == nil)
    }

    @Test func theMacsToggleEnvironmentIsUnaffected() {
        // A plain RemoteControlEnvironment still takes the audio/toggle path (see RemoteControlTests);
        // here only check that the explicit marker protocol isn't adopted by accident.
        #expect((Rig().media as RemoteControlEnvironment) is ExplicitPlaybackEnvironment)
    }
}

@Suite(.timeLimit(.minutes(1))) struct CommandTimeoutTests {
    /// A "busctl" that never exits (and ignores nothing special): the answer is nil, soon.
    @Test func aCommandThatNeverExitsIsKilledAndAnswersNothing() {
        let start = Date()
        let r = CommandRunner.run("/bin/sleep", ["60"], timeout: 0.4)
        #expect(r == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func outputLargerThanAPipeIsDrainedWhileTheCommandRuns() throws {
        let r = try #require(CommandRunner.run("/bin/sh", ["-c", "head -c 400000 /dev/zero | tr '\\0' x; head -c 400000 /dev/zero | tr '\\0' y 1>&2"], timeout: 10))
        #expect(r.status == 0)
        #expect(r.stdout.count == 400_000 && r.stderr.count == 400_000)
    }

    @Test func aWedgedBusIsAFailedRefreshNotAHang() {
        let m = MediaController(backend: BusctlBackend(executable: "/bin/sleep", timeout: 0.3))
        let start = Date()
        #expect(m.refresh() == false)      // `sleep --user list ...` is an error at once; use a real wedge below
        #expect(m.perform(.pause) == false)
        #expect(m.playbackState() == .unknown)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func aBusctlThatHangsTimesOut() throws {
        let dir = NSTemporaryDirectory() + "halltone-hang-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/busctl"
        try "#!/bin/sh\nsleep 60\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let m = MediaController(backend: BusctlBackend(executable: script, timeout: 0.3))
        let start = Date()
        #expect(m.playbackState() == .unknown)
        #expect(m.perform(.play) == false)
        #expect(m.pausePlayback() == nil)
        #expect(Date().timeIntervalSince(start) < 8)
    }
}
