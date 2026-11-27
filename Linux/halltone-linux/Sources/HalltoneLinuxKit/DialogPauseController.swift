import Foundation
import HalltoneCore
import HalltoneDialog
import HalltoneSenderCore
#if canImport(os)
import os
#endif

private let log = Logger(subsystem: Constants.logSubsystem, category: "Dialog")

/// Turns detector events into REMOTE_CONTROL requests, on its own thread: the machine decides,
/// the client sends (blocking up to 5 × 300 ms per request, one request at a time).
///
/// Every dialog event, request and ack is logged on one line each, so a tuning session can be
/// read back from the journal (see the README).
public final class DialogPauseController {
    private let lock = NSLock()
    private let machine: DialogPauseMachine
    private let client: RemoteSending
    private let wake = DispatchSemaphore(value: 0)
    private var running = false
    private var enabled: Bool
    private var thread: Thread?
    private var speechAge = 0                     // detector's msSinceSpeech …
    private var speechSampledAt = 0.0             // … as of this time
    private var lastAck: String?
    private var lastAckAt = 0.0
    private var loggedOneLiner = false
    /// What is being paused, for the log and `status`: "Mac" or "local player".
    private let targetName: String

    public init(timing: DialogPauseTiming, client: RemoteSending, enabled: Bool, targetName: String = "Mac") {
        self.targetName = targetName
        machine = DialogPauseMachine(timing: timing)
        self.client = client
        self.enabled = enabled
    }

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        let t = Thread { [self] in run() }
        t.name = "com.halltone.dialog.remote"
        thread = t
        t.start()
    }

    /// Stops the worker; if a pause is in effect, asks the Mac to resume (once, within ~1.5 s).
    public func stop() {
        lock.lock(); running = false; lock.unlock()
        wake.signal()
        perform(machineCancel(), reason: "stopping")
    }

    public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }

    public func setEnabled(_ on: Bool) {
        lock.lock()
        let changed = enabled != on
        enabled = on
        lock.unlock()
        guard changed else { return }
        log.notice("dialog pause \(on ? "ON" : "OFF")")
        if !on { perform(machineCancel(), reason: "turned off") }
        wake.signal()
    }

    /// From the detector thread.
    public func handle(_ event: DialogEvent) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        let now = monotonicNow()
        switch event {
        case .started(let t, let d):
            machine.dialogStarted(time: t, detectedAt: d, now: now)
            loggedOneLiner = false
            let lagMs = Int((d - t) * 1000)
            var next = "pause in 0 ms"
            if case .pending(let at) = machine.phase { next = "pause in \(max(0, Int((at - now) * 1000))) ms if speech continues (minDialogMs \(machine.timing.minDialogMs))" }
            else if machine.phase == .paused { next = "already paused (cancelled the pending resume)" }
            log.notice("dialog STARTED at stream \(seconds(t)) s (known at \(seconds(d)) s, detection lag \(lagMs) ms) → \(next)")
        case .ended(let t, let d):
            let was = machine.phase
            machine.dialogEnded(time: t, detectedAt: d, now: now)
            let lagMs = Int((d - t) * 1000)
            var next = "nothing was paused, nothing to resume"
            if case .resuming(let at) = machine.phase { next = "resume in \(max(0, Int((at - now) * 1000))) ms (resumeDelayMs \(machine.timing.resumeDelayMs))" }
            else if case .pending = was { next = "never paused (a one-liner shorter than minDialogMs)" }
            log.notice("dialog ENDED at stream \(seconds(t)) s (known at \(seconds(d)) s, detection lag \(lagMs) ms) → \(next)")
        }
        lock.unlock()
        wake.signal()
    }

    /// From the detector thread after each chunk.
    public func noteSpeech(msSince: Int) {
        lock.lock(); speechAge = msSince; speechSampledAt = monotonicNow(); lock.unlock()
    }

    /// One word for the tray: off, idle, pending, paused or resuming.
    public var phaseWord: String {
        lock.lock(); defer { lock.unlock() }
        if !enabled { return "off" }
        switch machine.phase {
        case .idle: return "idle"
        case .pending: return "pending"
        case .paused: return "paused"
        case .resuming: return "resuming"
        }
    }

    public func statusText() -> String {
        lock.lock(); defer { lock.unlock() }
        var phase: String
        switch machine.phase {
        case .idle: phase = "idle (no dialog)"
        case .pending: phase = "dialog heard, waiting minDialogMs before pausing"
        case .paused: phase = "\(targetName) paused, dialog going on"
        case .resuming: phase = "dialog ended, waiting resumeDelayMs before resuming"
        }
        if !enabled { phase = "off" }
        var s = "dialog pause: \(enabled ? "on" : "off"); state: \(phase)"
        if let a = lastAck { s += "; last answer: \(a) \(Int(monotonicNow() - lastAckAt)) s ago" }
        return s
    }

    // MARK: -

    private func run() {
        while true {
            _ = wake.wait(timeout: .now() + 0.05)
            lock.lock()
            if !running { lock.unlock(); return }
            var action: PauseAction?
            if enabled {
                action = machine.tick(now: monotonicNow(), msSinceSpeech: speechAge, sampledAt: speechSampledAt)
                if machine.skippedOneLiner, !loggedOneLiner {
                    loggedOneLiner = true
                    log.notice("dialog going on but speech stopped before minDialogMs elapsed: holding off the pause")
                }
            }
            lock.unlock()
            perform(action, reason: nil)
        }
    }

    private func machineCancel() -> PauseAction? { lock.lock(); defer { lock.unlock() }; return machine.cancel() }

    private func perform(_ action: PauseAction?, reason: String?) {
        guard let action else { return }
        let command: RemoteCommand = action == .pause ? .pauseForPeer : .resumeForPeer
        let name = action == .pause ? "pauseForPeer" : "resumeForPeer"
        log.notice("→ \(name)\(reason.map { " (\($0))" } ?? "")")
        let out = client.send(command)
        lock.lock()
        if action == .pause { machine.pauseAnswered(out.result) }
        lastAck = out.result.map { "\(name) → \("\($0)")" } ?? "\(name) → no answer"
        lastAckAt = monotonicNow()
        lock.unlock()
        let where_ = out.target ?? "no target"
        if let r = out.result {
            let answer = "\(r)"
            let why = out.note.map { " (\($0))" } ?? self.hint(action, r)
            log.notice("← \(name) id \(out.requestID) to \(where_): \(answer) (attempt \(out.attempts), \(out.elapsedMs) ms)\(why)")
        } else {
            log.error("← \(name) id \(out.requestID) to \(where_): NO ANSWER (\(out.error ?? "unknown"), \(out.attempts) attempts, \(out.elapsedMs) ms)")
        }
    }

    private func hint(_ action: PauseAction, _ r: RemoteResult) -> String {
        switch r {
        case .notPlaying: return " (nothing was playing on the \(targetName), so nothing was paused)"
        case .resumeSkipped: return " (the \(targetName) left it alone: playback was changed since the pause)"
        case .badPairingCode: return " (check dialogPause.pairingCode: it is the Mac's code)"
        case .disabled: return " (the Mac's \"Let paired devices pause playback\" switch is off)"
        case .failed: return " (the \(targetName) couldn't tell whether it is playing\(targetName == "Mac" ? ", or lacks Accessibility permission" : " (is a media player running?)"))"
        default: return ""
        }
    }

}

private func seconds(_ v: Double) -> String { String(format: "%.2f", v) }
