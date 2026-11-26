import Foundation
import HalltoneCore

/// What the Mac should be asked to do.
public enum PauseAction: Equatable { case pause, resume }

public struct DialogPauseTiming: Equatable {
    /// A dialog has to last this long (from the first speech) before the Mac is paused, so a
    /// one-liner doesn't stop the video.
    public var minDialogMs = 600
    /// Resume this long after the dialog's last speech (never earlier than the moment the detector
    /// reports the end, which is `endSilenceMs` = 1200 ms after the last speech).
    public var resumeDelayMs = 1500
    /// At the moment of pausing, speech must have been heard within this long, else it was a one-liner.
    public var oneLinerGapMs = 500
    public init() {}
}

/// The decision logic: dialog events in, "pause now" / "resume now" out. No threads or sockets, so
/// it is unit tested with a virtual clock. All times are monotonic seconds; not thread-safe.
public final class DialogPauseMachine {
    public enum Phase: Equatable {
        case idle
        /// A dialog is going on; the pause goes out at `pauseAt` if speech is still being heard.
        case pending(pauseAt: Double)
        /// Pause sent for the current dialog.
        case paused
        /// The dialog ended; resume goes out at `at`.
        case resuming(at: Double)
    }

    public var timing: DialogPauseTiming
    public private(set) var phase: Phase = .idle
    /// A pause was sent and may be in effect on the Mac: a resume is due.
    public private(set) var resumeDue = false
    /// Why the last tick didn't pause (for the log), if it didn't.
    public private(set) var skippedOneLiner = false

    public init(timing: DialogPauseTiming = DialogPauseTiming()) { self.timing = timing }

    /// `time`/`detectedAt` are the detector's stream seconds; their difference is its latency.
    public func dialogStarted(time: Double, detectedAt: Double, now: Double) {
        let lag = max(0, detectedAt - time)
        func startPending() {
            skippedOneLiner = false
            phase = .pending(pauseAt: now + max(0, Double(timing.minDialogMs) / 1000 - lag))
        }
        switch phase {
        case .idle:
            startPending()
        case .resuming:
            // More dialog before the resume went out: stay paused.
            if resumeDue { phase = .paused } else { startPending() }
        case .pending, .paused:
            break
        }
    }

    public func dialogEnded(time: Double, detectedAt: Double, now: Double) {
        let lag = max(0, detectedAt - time)
        switch phase {
        case .idle, .resuming:
            break
        case .pending:
            phase = .idle
        case .paused:
            let wait = max(0, Double(timing.resumeDelayMs) / 1000 - lag)
            phase = .resuming(at: now + wait)
        }
        // A pause whose answer was lost can't be told from one that worked: the resume is still
        // due, and the Mac skips it if it never paused.
        if phase == .idle, resumeDue { phase = .resuming(at: now) }
    }

    /// `msSinceSpeech`: age of the last speech frame as of `sampledAt`.
    public func tick(now: Double, msSinceSpeech: Int, sampledAt: Double) -> PauseAction? {
        switch phase {
        case .pending(let pauseAt):
            guard now >= pauseAt else { return nil }
            let age = Double(msSinceSpeech) + max(0, now - sampledAt) * 1000
            if age > Double(timing.oneLinerGapMs) {
                skippedOneLiner = true       // not speaking now; look again on the next tick
                return nil
            }
            skippedOneLiner = false
            phase = .paused
            resumeDue = true
            return .pause
        case .resuming(let at):
            guard now >= at else { return nil }
            phase = .idle
            let due = resumeDue
            resumeDue = false
            return due ? .resume : nil
        case .idle, .paused:
            return nil
        }
    }

    /// The Mac's answer to the pause (nil: none arrived). A definite "it didn't pause" cancels the resume.
    public func pauseAnswered(_ result: RemoteResult?) {
        switch result {
        case .notPlaying?, .failed?, .badPairingCode?, .disabled?: resumeDue = false
        default: break
        }
    }

    /// The feature was turned off or the process is stopping: a resume is due if we paused.
    public func cancel() -> PauseAction? {
        let due = resumeDue
        phase = .idle
        resumeDue = false
        return due ? .resume : nil
    }
}
