import Foundation
import HalltoneCore
#if canImport(os)
import os
#endif

private let log = Logger(subsystem: Constants.logSubsystem, category: "Dialog")

// Dialog pause for a video on the SAME PC (#20): `dialogPause.target = "local"`.
//
// Three pieces, none of which touches DialogPauseMachine:
//  - LocalRemoteSender: the controller's `RemoteSending`, answered by this PC's MPRIS player through
//    the same RemoteControlCoordinator the Mac uses, so "resume only if still ours" is the same rule.
//  - PauseLoopGuard: a safety net that stops pausing when the same player is paused too often.
//  - PlayerStreamMap: which audio streams belong to the player we control, so the detector can
//    refuse to listen to them (the primary protection against the pause/resume feedback loop).

/// REMOTE_CONTROL without the network: pause and resume go to `MediaController` (MPRIS). Every call
/// is bounded: the coordinator runs on a serial queue and `send` gives up waiting after `deadline`
/// seconds (the D-Bus calls underneath each have their own 2 s timeout in `CommandRunner`).
public final class LocalRemoteSender: RemoteSending {
    public static let peer = "this PC"
    private let coordinator: RemoteControlCoordinator
    private let queue = DispatchQueue(label: "com.halltone.dialog.local")
    private let deadline: TimeInterval
    private var nextID: UInt32 = 0
    private let idLock = NSLock()

    public init(media: MediaController, deadline: TimeInterval = 4) {
        var timing = RemoteControlTiming()
        timing.maxResumeAge = 3600     // a long cutscene still gets its resume
        coordinator = RemoteControlCoordinator(environment: media, timing: timing)
        self.deadline = deadline
    }

    public func send(_ command: RemoteCommand) -> RemoteSendOutcome {
        idLock.lock(); nextID &+= 1; let id = nextID; idLock.unlock()
        var out = RemoteSendOutcome()
        out.requestID = id
        out.target = "this PC (MPRIS)"
        out.attempts = 1
        let started = monotonicNow()
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        queue.async { [coordinator] in
            box.set(coordinator.handle(command, peer: Self.peer, requestID: id, enabled: true))
            done.signal()
        }
        if done.wait(timeout: .now() + deadline) == .success {
            out.result = box.value
        } else {
            out.error = "the media player didn't answer within \(Int(deadline)) s"
        }
        out.elapsedMs = Int((monotonicNow() - started) * 1000)
        return out
    }

    private final class ResultBox {
        private let lock = NSLock()
        private var v: RemoteResult?
        func set(_ r: RemoteResult) { lock.lock(); v = r; lock.unlock() }
        var value: RemoteResult? { lock.lock(); defer { lock.unlock() }; return v }
    }
}

/// Wraps a sender: after more than `maxPauses` pauses within `window` seconds it stops pausing
/// (answering `.disabled`, which also cancels the resume that would have followed) and says so.
/// The block lasts `cooldown` seconds, or until `reset()` (dialog pause switched off and on again).
/// Resumes always go through, so a pause that did happen is never left in place.
public final class PauseLoopGuard: RemoteSending {
    private let inner: RemoteSending
    private let maxPauses: Int
    private let window: Double
    private let cooldown: Double
    private let clock: () -> Double
    private let lock = NSLock()
    private var pauses: [Double] = []
    private var blockedUntil: Double?

    public init(_ inner: RemoteSending, maxPauses: Int = 4, window: Double = 60, cooldown: Double = 600,
                clock: (() -> Double)? = nil) {
        self.inner = inner; self.maxPauses = maxPauses; self.window = window; self.cooldown = cooldown; self.clock = clock ?? { monotonicNow() }
    }

    public var isTripped: Bool {
        lock.lock(); defer { lock.unlock() }
        if let b = blockedUntil, clock() < b { return true }
        return false
    }

    public func reset() { lock.lock(); pauses = []; blockedUntil = nil; lock.unlock() }

    public func send(_ command: RemoteCommand) -> RemoteSendOutcome {
        guard command == .pauseForPeer else { return inner.send(command) }
        let now = clock()
        lock.lock()
        if let b = blockedUntil, now >= b { blockedUntil = nil; pauses = [] }
        pauses.removeAll { now - $0 > window }
        let blocked = blockedUntil != nil
        let trips = !blocked && pauses.count >= maxPauses
        if trips { blockedUntil = now + cooldown }
        let count = pauses.count
        lock.unlock()
        if trips {
            log.error("LOOP GUARD: \(count) pauses of the local player within \(Int(self.window)) s: the dialog detector is probably hearing the video itself. Not pausing for the next \(Int(self.cooldown / 60)) min (or until `halltone-linux dialog off` then `on`). Set dialogPause.sourceApp to the game's application name (see `halltone-linux apps`).")
        }
        if trips || blocked {
            var out = RemoteSendOutcome()
            out.target = "this PC (MPRIS)"
            out.result = .disabled
            out.note = "loop guard: too many pauses (more than \(maxPauses) in \(Int(window)) s), not pausing"
            return out
        }
        let out = inner.send(command)
        if out.result == .paused {
            lock.lock(); pauses.append(now); lock.unlock()
        }
        return out
    }
}

/// Which audio streams are the controlled player's. A sink input is the player's when one of its
/// names (`application.name`, `application.process.binary`, `media.name`) matches the player's
/// MPRIS bus-name stem (`firefox.instance_1_42` → `firefox`) or its identity ("Mozilla Firefox"),
/// case-insensitively; Chromium-family players, whose bus is `chromium` but whose audio is called
/// `chrome`, are matched through a small alias list.
public enum PlayerStreamMap {
    /// Lowercased keys naming a player's streams.
    public static func keys(for player: MPRISPlayer) -> [String] {
        var keys: [String] = []
        var stem = player.shortName.lowercased()
        if let dot = stem.firstIndex(of: ".") { stem = String(stem[..<dot]) }
        if !stem.isEmpty { keys.append(stem) }
        let identity = player.identity.lowercased().trimmingCharacters(in: .whitespaces)
        if !identity.isEmpty { keys.append(identity) }
        if stem.contains("chrom") { keys.append(contentsOf: ["chrome", "chromium"]) }
        return keys
    }

    public static func keys(for players: [MPRISPlayer]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for k in players.flatMap(keys(for:)) where seen.insert(k).inserted { out.append(k) }
        return out
    }

    /// Whether a stream whose names are `names` belongs to a player with these `keys`.
    public static func isExcluded(names: [String], keys: [String]) -> Bool {
        for raw in names {
            let n = raw.lowercased()
            guard !n.isEmpty else { continue }
            for k in keys where !k.isEmpty {
                if n == k || n.contains(k) { return true }
                if n.count >= 3, k.contains(n) { return true }   // "firefox" inside "mozilla firefox"
            }
        }
        return false
    }
}

public extension MediaController {
    /// Keys naming the streams of every player this controller may pause (the whole set: which one is
    /// "chosen" can change while a dialog is on). From the polled snapshot, so it never waits on D-Bus.
    func excludedStreamKeys() -> [String] { PlayerStreamMap.keys(for: eligiblePlayers()) }
}
