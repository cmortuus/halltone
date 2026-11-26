import Testing
import Foundation
import HalltoneCore
@testable import HalltoneLinuxKit

/// The pause/resume decisions on a virtual clock.
@Suite struct DialogPauseMachineTests {
    func machine(min: Int = 600, resume: Int = 1500) -> DialogPauseMachine {
        var t = DialogPauseTiming()
        t.minDialogMs = min
        t.resumeDelayMs = resume
        return DialogPauseMachine(timing: t)
    }

    @Test func pausesAfterMinDialogAndResumesAfterTheDelay() {
        let m = machine()
        m.dialogStarted(time: 10, detectedAt: 10.3, now: 100)
        #expect(m.phase == .pending(pauseAt: 100.3))   // minDialogMs 600 minus the 300 ms detection lag
        #expect(m.tick(now: 100.2, msSinceSpeech: 0, sampledAt: 100.2) == nil)
        #expect(m.tick(now: 100.3, msSinceSpeech: 20, sampledAt: 100.3) == .pause)
        #expect(m.tick(now: 100.4, msSinceSpeech: 20, sampledAt: 100.4) == nil)   // only once

        // The detector reports the end 1.2 s after the last speech: 1.5 s - 1.2 s left to wait.
        m.dialogEnded(time: 15, detectedAt: 16.2, now: 200)
        #expect(m.tick(now: 200.2, msSinceSpeech: 0, sampledAt: 200.2) == nil)
        #expect(m.tick(now: 200.3, msSinceSpeech: 0, sampledAt: 200.3) == .resume)
        #expect(m.tick(now: 201, msSinceSpeech: 0, sampledAt: 201) == nil)
        #expect(m.phase == .idle)
    }

    @Test func aResumeDelayShorterThanTheDetectionLagResumesAtOnce() {
        let m = machine(resume: 500)
        m.dialogStarted(time: 1, detectedAt: 1.3, now: 10)
        _ = m.tick(now: 11, msSinceSpeech: 0, sampledAt: 11)
        m.dialogEnded(time: 5, detectedAt: 6.2, now: 50)
        #expect(m.tick(now: 50, msSinceSpeech: 0, sampledAt: 50) == .resume)
    }

    @Test func aOneLinerNeverPauses() {
        let m = machine()
        m.dialogStarted(time: 10, detectedAt: 10.3, now: 100)
        // At pause time the speech stopped 900 ms ago: a one-liner.
        #expect(m.tick(now: 100.4, msSinceSpeech: 900, sampledAt: 100.4) == nil)
        #expect(m.skippedOneLiner)
        // The detector reports the end later: nothing was paused, nothing to resume.
        m.dialogEnded(time: 10.5, detectedAt: 11.7, now: 101.5)
        #expect(m.phase == .idle)
        #expect(m.tick(now: 110, msSinceSpeech: 0, sampledAt: 110) == nil)
    }

    @Test func speechThatResumesLaterInTheSameDialogStillPauses() {
        let m = machine()
        m.dialogStarted(time: 10, detectedAt: 10.3, now: 100)
        #expect(m.tick(now: 100.4, msSinceSpeech: 900, sampledAt: 100.4) == nil)
        #expect(m.tick(now: 101.0, msSinceSpeech: 100, sampledAt: 101.0) == .pause)
    }

    @Test func theAgeOfTheSpeechSampleCounts() {
        let m = machine()
        m.dialogStarted(time: 10, detectedAt: 10.3, now: 100)
        // 300 ms since speech when sampled, sampled 400 ms ago: 700 ms now, over the 500 ms gap.
        #expect(m.tick(now: 100.4, msSinceSpeech: 300, sampledAt: 100.0) == nil)
    }

    @Test func moreDialogBeforeTheResumeKeepsItPaused() {
        let m = machine()
        m.dialogStarted(time: 1, detectedAt: 1.3, now: 10)
        #expect(m.tick(now: 11, msSinceSpeech: 0, sampledAt: 11) == .pause)
        m.dialogEnded(time: 5, detectedAt: 6.2, now: 20)
        m.dialogStarted(time: 6.4, detectedAt: 6.7, now: 20.2)      // before resume went out
        #expect(m.phase == .paused)
        #expect(m.tick(now: 25, msSinceSpeech: 0, sampledAt: 25) == nil)
        m.dialogEnded(time: 9, detectedAt: 10.2, now: 30)
        #expect(m.tick(now: 30.3, msSinceSpeech: 0, sampledAt: 30.3) == .resume)
    }

    @Test func aPauseTheMacRefusedIsNotResumed() {
        for refusal: RemoteResult in [.notPlaying, .failed, .badPairingCode, .disabled] {
            let m = machine()
            m.dialogStarted(time: 1, detectedAt: 1.3, now: 10)
            #expect(m.tick(now: 11, msSinceSpeech: 0, sampledAt: 11) == .pause)
            m.pauseAnswered(refusal)
            m.dialogEnded(time: 5, detectedAt: 6.2, now: 20)
            #expect(m.tick(now: 30, msSinceSpeech: 0, sampledAt: 30) == nil, "\(refusal)")
        }
    }

    @Test func aPauseWithoutAnAnswerIsStillResumed() {
        // The ack may have been lost after the Mac paused; the Mac skips a resume it doesn't owe.
        for answer: RemoteResult? in [nil, .paused] {
            let m = machine()
            m.dialogStarted(time: 1, detectedAt: 1.3, now: 10)
            _ = m.tick(now: 11, msSinceSpeech: 0, sampledAt: 11)
            m.pauseAnswered(answer)
            m.dialogEnded(time: 5, detectedAt: 6.2, now: 20)
            #expect(m.tick(now: 30, msSinceSpeech: 0, sampledAt: 30) == .resume)
        }
    }

    @Test func cancelResumesOnlyWhatWasPaused() {
        let m = machine()
        #expect(m.cancel() == nil)
        m.dialogStarted(time: 1, detectedAt: 1.3, now: 10)
        #expect(m.cancel() == nil)             // pending, nothing sent yet
        m.dialogStarted(time: 1, detectedAt: 1.3, now: 10)
        _ = m.tick(now: 11, msSinceSpeech: 0, sampledAt: 11)
        #expect(m.cancel() == .resume)
        #expect(m.cancel() == nil)
        #expect(m.phase == .idle)
    }

    @Test func zeroMinDialogPausesOnTheFirstTick() {
        let m = machine(min: 0)
        m.dialogStarted(time: 1, detectedAt: 1.3, now: 10)
        #expect(m.tick(now: 10, msSinceSpeech: 0, sampledAt: 10) == .pause)
    }
}
