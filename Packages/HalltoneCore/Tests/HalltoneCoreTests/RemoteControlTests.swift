import Testing
import Foundation
@testable import HalltoneCore

/// A scripted Mac: a virtual clock, whatever audio history the test sets up, and a media key that
/// toggles `playing` like the real one does.
private final class FakeMac: RemoteControlEnvironment {
    var time: TimeInterval = 1_000
    var audible: TimeInterval?
    var captureStartedAt: TimeInterval?
    /// What a probe capture hears; nil = can't tell.
    var probeResult: Bool? = false
    var keyWorks = true
    private(set) var presses = 0
    private(set) var probes = 0
    /// Is sound coming out? The toggle flips it; `tick` keeps `audible` current while it plays.
    var playing = false
    /// Runs on every `sleep`, e.g. to make sound return mid-wait.
    var onSleep: ((FakeMac) -> Void)?

    func now() -> TimeInterval { time }
    func sleep(_ seconds: TimeInterval) { time += seconds; onSleep?(self) }
    func lastAudible() -> TimeInterval? { audible }
    func captureStart() -> TimeInterval? { captureStartedAt }
    func probeAudible(window: TimeInterval) -> Bool? {
        probes += 1
        time += window
        if let probeResult, probeResult { audible = time }
        return probeResult
    }
    func pressPlayPause() -> Bool {
        guard keyWorks else { return false }
        presses += 1
        playing.toggle()
        return true
    }

    /// The capture has been running for a while and last heard sound `ago` seconds back.
    func capturing(heardAgo ago: TimeInterval?) {
        captureStartedAt = time - 60
        audible = ago.map { time - $0 }
    }
    func advance(_ s: TimeInterval) { time += s }
}

private func make(_ mac: FakeMac) -> RemoteControlCoordinator { RemoteControlCoordinator(environment: mac) }

@Suite struct RemoteControlTests {
    // MARK: pause

    @Test func pausesWhatIsPlaying() {
        let mac = FakeMac(); mac.capturing(heardAgo: 0.05)
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true) == .paused)
        #expect(mac.presses == 1)
        #expect(c.pausedForPeer == "PC")
    }

    @Test func nothingPlayingMeansNoKeyPressAndNoMark() {
        let mac = FakeMac(); mac.capturing(heardAgo: 30)
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true) == .notPlaying)
        #expect(mac.presses == 0)
        #expect(c.pausedForPeer == nil)
        // Never heard anything at all.
        let fresh = FakeMac(); fresh.capturing(heardAgo: nil)
        #expect(make(fresh).handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true) == .notPlaying)
        #expect(fresh.presses == 0)
    }

    @Test func quietMomentWaitsForSoundThenPauses() {
        let mac = FakeMac(); mac.capturing(heardAgo: 0.8)
        mac.onSleep = { m in if m.time > 1_000.5 { m.audible = m.time } } // sound returns after 0.5 s
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true) == .paused)
        #expect(mac.presses == 1)
    }

    @Test func justPausedByHandWaitsOutTwoSecondsAndDoesNotPress() {
        // Silent for 0.8 s and stays silent: the user paused a moment ago. A press would restart it.
        let mac = FakeMac(); mac.capturing(heardAgo: 0.8)
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true) == .notPlaying)
        #expect(mac.presses == 0)
        #expect(c.pausedForPeer == nil)
        #expect(mac.time - 1_000 <= 1.5) // waited out the rest of the 2 s, not longer
    }

    @Test func noCaptureProbesInsteadOfGuessing() {
        let mac = FakeMac(); mac.captureStartedAt = nil; mac.probeResult = true
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true) == .paused)
        #expect(mac.probes == 1)
        #expect(mac.presses == 1)

        let quiet = FakeMac(); quiet.probeResult = false
        #expect(make(quiet).handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true) == .notPlaying)
        #expect(quiet.presses == 0)
    }

    @Test func probeThatCannotTellFailsWithoutPressing() {
        let mac = FakeMac(); mac.probeResult = nil
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true) == .failed)
        #expect(mac.presses == 0)
        #expect(c.pausedForPeer == nil)
    }

    @Test func freshCaptureIsProbedNotTrusted() {
        // A capture that started 100 ms ago can't have heard anything yet: "silent" means nothing.
        let mac = FakeMac(); mac.captureStartedAt = mac.time - 0.1; mac.audible = nil; mac.probeResult = true
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true) == .paused)
        #expect(mac.probes == 1)
    }

    @Test func keyFailureIsReportedAndRecordsNothing() {
        let mac = FakeMac(); mac.capturing(heardAgo: 0); mac.keyWorks = false
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true) == .failed)
        #expect(c.pausedForPeer == nil)
    }

    @Test func disabledDoesNothing() {
        let mac = FakeMac(); mac.capturing(heardAgo: 0)
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: false) == .disabled)
        #expect(c.handle(.resumeForPeer, peer: "PC", requestID: 2, enabled: false) == .disabled)
        #expect(mac.presses == 0)
    }

    // MARK: resume

    /// Pauses for "PC" and lets the audio tail die away.
    private func pausedMac() -> (FakeMac, RemoteControlCoordinator) {
        let mac = FakeMac(); mac.playing = true; mac.capturing(heardAgo: 0)
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true) == .paused)
        mac.advance(5)
        return (mac, c)
    }

    @Test func resumesWhenStillPaused() {
        let (mac, c) = pausedMac()
        #expect(c.handle(.resumeForPeer, peer: "PC", requestID: 2, enabled: true) == .resumed)
        #expect(mac.presses == 2)
        #expect(mac.playing)
        #expect(c.pausedForPeer == nil)
    }

    @Test func audioRightAfterOurPauseIsTailNotTheUser() {
        let mac = FakeMac(); mac.playing = true; mac.capturing(heardAgo: 0)
        let c = make(mac)
        _ = c.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true)
        mac.advance(0.4); mac.audible = mac.time // fading out
        mac.advance(5)
        #expect(c.handle(.resumeForPeer, peer: "PC", requestID: 2, enabled: true) == .resumed)
    }

    @Test func userResumedByHandSkipsResumeAndPressesNothing() {
        let (mac, c) = pausedMac()
        mac.audible = mac.time - 1 // user hit play 1 s ago: audible, long after the pause
        mac.playing = true
        #expect(c.handle(.resumeForPeer, peer: "PC", requestID: 2, enabled: true) == .resumeSkipped)
        #expect(mac.presses == 1) // only our pause
        #expect(c.pausedForPeer == nil) // cleared either way
        // And a second resume has nothing to act on.
        #expect(c.handle(.resumeForPeer, peer: "PC", requestID: 3, enabled: true) == .resumeSkipped)
        #expect(mac.presses == 1)
    }

    @Test func expiresAfterTenMinutes() {
        let (mac, c) = pausedMac()
        mac.advance(600)
        #expect(c.handle(.resumeForPeer, peer: "PC", requestID: 2, enabled: true) == .resumeSkipped)
        #expect(mac.presses == 1)
        #expect(c.pausedForPeer == nil)
    }

    @Test func justUnderTenMinutesStillResumes() {
        let (mac, c) = pausedMac()
        mac.advance(590) // 595 s after the pause
        #expect(c.handle(.resumeForPeer, peer: "PC", requestID: 2, enabled: true) == .resumed)
    }

    @Test func resumeWithoutPauseDoesNothing() {
        let mac = FakeMac(); mac.capturing(heardAgo: nil)
        #expect(make(mac).handle(.resumeForPeer, peer: "PC", requestID: 1, enabled: true) == .resumeSkipped)
        #expect(mac.presses == 0)
    }

    @Test func onlyThePausingPeerCanResume() {
        let (mac, c) = pausedMac()
        #expect(c.handle(.resumeForPeer, peer: "Other", requestID: 1, enabled: true) == .resumeSkipped)
        #expect(mac.presses == 1)
        #expect(c.pausedForPeer == "PC") // the other peer's attempt doesn't wipe PC's pause
        #expect(c.handle(.resumeForPeer, peer: "PC", requestID: 2, enabled: true) == .resumed)
    }

    @Test func resumeProbesWhenCaptureWasntRunningSincePause() {
        // Paused via a probe with no phone listening: capture is off afterwards.
        let mac = FakeMac(); mac.probeResult = true; mac.playing = true
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true) == .paused)
        mac.advance(5)
        mac.probeResult = false // nothing audible: still paused
        #expect(c.handle(.resumeForPeer, peer: "PC", requestID: 2, enabled: true) == .resumed)
        #expect(mac.probes == 2)
        #expect(mac.presses == 2)

        // Same again, but the probe hears the user's own playback.
        let mac2 = FakeMac(); mac2.probeResult = true
        let c2 = make(mac2)
        _ = c2.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true)
        mac2.advance(5)
        #expect(c2.handle(.resumeForPeer, peer: "PC", requestID: 2, enabled: true) == .resumeSkipped)
        #expect(mac2.presses == 1)
    }

    @Test func resumeThatCannotTellDoesNotPressAndKeepsThePause() {
        let mac = FakeMac(); mac.probeResult = true
        let c = make(mac)
        _ = c.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true)
        mac.advance(5); mac.probeResult = nil
        #expect(c.handle(.resumeForPeer, peer: "PC", requestID: 2, enabled: true) == .failed)
        #expect(mac.presses == 1)
        #expect(c.pausedForPeer == "PC")
    }

    // MARK: repeats and retries

    @Test func repeatedPauseWhileAlreadyPausedIsIdempotent() {
        let mac = FakeMac(); mac.playing = true; mac.capturing(heardAgo: 0)
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 1, enabled: true) == .paused)
        mac.advance(30)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 2, enabled: true) == .paused)
        #expect(mac.presses == 1) // no second toggle
        // The second request extended the expiry: 9 minutes later we're past 10 minutes since the first.
        mac.advance(540 + 30)
        #expect(c.handle(.resumeForPeer, peer: "PC", requestID: 3, enabled: true) == .resumed)
    }

    @Test func pauseFromAnotherPeerWhilePausedDoesNotToggleOrTakeOver() {
        let (mac, c) = pausedMac()
        #expect(c.handle(.pauseForPeer, peer: "Other", requestID: 1, enabled: true) == .paused)
        #expect(mac.presses == 1)
        #expect(c.pausedForPeer == "PC")
    }

    @Test func duplicateRequestIDIsAnsweredWithoutActingTwice() {
        let mac = FakeMac(); mac.playing = true; mac.capturing(heardAgo: 0)
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 77, enabled: true) == .paused)
        mac.advance(0.3)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 77, enabled: true) == .paused)
        #expect(mac.presses == 1)

        mac.advance(5)
        #expect(c.handle(.resumeForPeer, peer: "PC", requestID: 78, enabled: true) == .resumed)
        mac.advance(0.3)
        // The retry of the resume must not press again (that would pause it).
        #expect(c.handle(.resumeForPeer, peer: "PC", requestID: 78, enabled: true) == .resumed)
        #expect(mac.presses == 2)
        #expect(mac.playing)
    }

    @Test func requestIDsAreRememberedPerPeerAndForgottenAfterAWhile() {
        let mac = FakeMac(); mac.capturing(heardAgo: 30)
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "A", requestID: 5, enabled: true) == .notPlaying)
        // Sound starts; the same id again from A is a retry: same answer, nothing pressed.
        mac.audible = mac.time
        #expect(c.handle(.pauseForPeer, peer: "A", requestID: 5, enabled: true) == .notPlaying)
        #expect(mac.presses == 0)
        // The same id from another peer is a different request.
        #expect(c.handle(.pauseForPeer, peer: "B", requestID: 5, enabled: true) == .paused)
        #expect(mac.presses == 1)
        // Long after, A reusing the id is a new request. (B's pause is gone by then: the sound it
        // paused has come back.)
        mac.advance(31); mac.audible = mac.time
        #expect(c.handle(.pauseForPeer, peer: "A", requestID: 5, enabled: true) == .paused)
        #expect(mac.presses == 2)
    }

    @Test func failedResultsAreNotCachedSoARetryCanSucceed() {
        let mac = FakeMac(); mac.capturing(heardAgo: 0); mac.keyWorks = false
        let c = make(mac)
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 9, enabled: true) == .failed)
        mac.keyWorks = true
        #expect(c.handle(.pauseForPeer, peer: "PC", requestID: 9, enabled: true) == .paused)
    }

    // MARK: refresh and notifications

    @Test func refreshClearsThePauseWhenTheUserResumes() {
        let (mac, c) = pausedMac()
        var seen: [String?] = []
        c.onChange = { seen.append($0) }
        c.refresh()
        #expect(c.pausedForPeer == "PC")
        mac.audible = mac.time // sound is back
        c.refresh()
        #expect(c.pausedForPeer == nil)
        #expect(seen == [nil])
    }

    @Test func refreshClearsAnExpiredPause() {
        let (mac, c) = pausedMac()
        mac.advance(600)
        c.refresh()
        #expect(c.pausedForPeer == nil)
    }

    @Test func clearForgetsThePause() {
        let (_, c) = pausedMac()
        c.clear()
        #expect(c.pausedForPeer == nil)
    }
}
