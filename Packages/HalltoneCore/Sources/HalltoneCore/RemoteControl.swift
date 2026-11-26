import Foundation

/// What `RemoteControlCoordinator` needs from the outside world. The Mac's Sender implements it
/// with the process tap and the media key; unit tests use a scripted fake with a virtual clock.
/// All times are monotonic seconds.
public protocol RemoteControlEnvironment: AnyObject {
    func now() -> TimeInterval
    func sleep(_ seconds: TimeInterval)
    /// When captured audio last wasn't near-silent; nil if never.
    func lastAudible() -> TimeInterval?
    /// When the capture that is running now started; nil when nothing is being captured.
    func captureStart() -> TimeInterval?
    /// Starts a brief capture (if none is running) and reports whether anything was audible
    /// within `window` seconds. nil: it could not tell (capture won't start, no permission).
    func probeAudible(window: TimeInterval) -> Bool?
    /// Presses the play/pause media key. False if it couldn't (Accessibility permission missing).
    func pressPlayPause() -> Bool
}

/// What an explicit-state player reports (Linux MPRIS), as opposed to the Mac's guess from audio.
public enum ExplicitPlayback: Equatable {
    /// A player is playing; `token` names what would be paused (player + track).
    case playing
    case notPlaying
    /// Couldn't ask (no bus, backend failed).
    case unknown
}

/// An environment that knows real playback state and has explicit Pause / Play, so the coordinator
/// needs no audio probing and no toggle. MPRIS on Linux implements it. The audio-based members of
/// `RemoteControlEnvironment` get inert defaults (they're never consulted in this mode).
///
/// A "token" identifies what we paused (the player and its current track); it is opaque here.
public protocol ExplicitPlaybackEnvironment: RemoteControlEnvironment {
    func playbackState() -> ExplicitPlayback
    /// Pauses what is playing (and checks that it took). Returns its token, nil if it couldn't.
    func pausePlayback() -> String?
    /// Plays the thing `token` names. False if it couldn't.
    func resumePlayback(token: String) -> Bool
    /// Still paused where we left it: that player exists, is Paused, and is on the same track.
    /// False means the user resumed by hand, changed track, or closed the player.
    func isStillPaused(token: String) -> Bool
}

public extension ExplicitPlaybackEnvironment {
    func lastAudible() -> TimeInterval? { nil }
    func captureStart() -> TimeInterval? { nil }
    func probeAudible(window: TimeInterval) -> Bool? { nil }
    func pressPlayPause() -> Bool { false }
}

public struct RemoteControlTiming {
    /// A pause is only undone within this long of the last pause request from that peer.
    public var maxResumeAge: TimeInterval = 600
    /// Audible this recently: playing, press at once.
    public var playingNow: TimeInterval = 0.25
    /// Not audible for this long: not playing. Between `playingNow` and this it's unclear whether
    /// the sound just stopped or the content has a quiet moment, so wait it out.
    public var notPlayingAfter: TimeInterval = 2.0
    /// Audio this soon after our own pause is its tail, not the user resuming.
    public var graceAfterPause: TimeInterval = 1.5
    /// Length of the probe capture used when nothing is being captured.
    public var probeWindow: TimeInterval = 0.5
    /// A capture younger than this may not have heard anything yet, so probe instead.
    public var warmCapture: TimeInterval = 0.5
    /// How long an answered request id is remembered, so a retry isn't acted on twice.
    public var dedupeWindow: TimeInterval = 30
    public init() {}
}

/// The decision logic behind REMOTE_CONTROL, with no CoreAudio in it.
///
/// The media key is a toggle, so the rules are: never press it unless we know whether something
/// is playing, and only undo a pause that is still in effect. Call `handle` and `refresh` from one
/// serial queue; `handle` can block for up to a few seconds (it may probe or wait).
public final class RemoteControlCoordinator {
    private struct Mark {
        var peer: String
        var pausedAt: TimeInterval
        /// Last pause request from the peer (extends the 10-minute expiry).
        var refreshedAt: TimeInterval
        /// Explicit environments: what was paused (see `ExplicitPlaybackEnvironment`).
        var token: String?
    }

    private struct Answered {
        var command: RemoteCommand
        var result: RemoteResult
        var at: TimeInterval
    }

    private enum Observation { case playing, notPlaying, unknown }

    public var timing: RemoteControlTiming
    private let env: RemoteControlEnvironment
    private var mark: Mark?
    private var answered: [String: [UInt32: Answered]] = [:]

    /// The peer that paused playback and hasn't resumed it (nil when no pause is in effect).
    public private(set) var pausedForPeer: String?
    /// Called whenever `pausedForPeer` changes.
    public var onChange: ((String?) -> Void)?

    public init(environment: RemoteControlEnvironment, timing: RemoteControlTiming = RemoteControlTiming()) {
        env = environment
        self.timing = timing
    }

    public func handle(_ command: RemoteCommand, peer: String, requestID: UInt32, enabled: Bool) -> RemoteResult {
        guard enabled else { return .disabled }
        let t = env.now()
        pruneAnswered(t)
        // A retry (the peer's 300 ms timeout) carries the same request id: repeat the answer.
        if let prior = answered[peer]?[requestID], prior.command == command { return prior.result }
        let result: RemoteResult
        switch command {
        case .pauseForPeer: result = pause(peer: peer)
        case .resumeForPeer: result = resume(peer: peer)
        }
        // A failure may be transient (probe couldn't start), so a retry gets another go.
        if result != .failed {
            answered[peer, default: [:]][requestID] = Answered(command: command, result: result, at: env.now())
        }
        return result
    }

    /// Drops the pause mark once it can no longer be resumed: expired, or the user resumed by hand
    /// (audio came back). Called about once a second so the menu's "Paused for" line goes away.
    public func refresh() {
        guard let m = mark else { return }
        if !isValid(m, at: env.now()) { setMark(nil) }
    }

    /// Forgets the pause (the feature was turned off).
    public func clear() { setMark(nil) }

    // MARK: - Pause

    private func pause(peer: String) -> RemoteResult {
        if var m = mark, isValid(m, at: env.now()) {
            // Already paused for someone. The same peer asking again just extends its expiry; another
            // peer isn't told anything false (it is paused) but doesn't take over the resume.
            if m.peer == peer { m.refreshedAt = env.now(); mark = m }
            return .paused
        }
        setMark(nil)
        if let explicit = env as? ExplicitPlaybackEnvironment { return pauseExplicit(explicit, peer: peer) }
        switch observePlaying() {
        case .unknown: return .failed
        case .notPlaying: return .notPlaying
        case .playing:
            guard env.pressPlayPause() else { return .failed }
            let t = env.now()
            setMark(Mark(peer: peer, pausedAt: t, refreshedAt: t))
            return .paused
        }
    }

    private func pauseExplicit(_ e: ExplicitPlaybackEnvironment, peer: String) -> RemoteResult {
        switch e.playbackState() {
        case .unknown: return .failed
        case .notPlaying: return .notPlaying
        case .playing:
            guard let token = e.pausePlayback() else { return .failed }
            let t = env.now()
            setMark(Mark(peer: peer, pausedAt: t, refreshedAt: t, token: token))
            return .paused
        }
    }

    /// Whether something is playing, without ever guessing: a capture that hasn't been running
    /// long enough to have heard anything is probed instead of trusted.
    private func observePlaying() -> Observation {
        let t = env.now()
        guard let start = env.captureStart(), t - start >= timing.warmCapture else {
            guard let heard = env.probeAudible(window: timing.probeWindow) else { return .unknown }
            return heard ? .playing : .notPlaying
        }
        let silent = silence(at: t)
        if silent < timing.playingNow { return .playing }
        if silent >= timing.notPlayingAfter { return .notPlaying }
        // Silent now but heard within 2 s: a quiet moment, or paused a moment ago. Pressing the
        // toggle in the second case would restart it, so wait for sound (press) or for 2 s of
        // silence (don't).
        let deadline = t + (timing.notPlayingAfter - silent)
        while env.now() < deadline {
            env.sleep(0.05)
            if silence(at: env.now()) < 0.1 { return .playing }
        }
        return .notPlaying
    }

    // MARK: - Resume

    private func resume(peer: String) -> RemoteResult {
        guard let m = mark, m.peer == peer else { return .resumeSkipped }
        let t = env.now()
        guard isValid(m, at: t) else { setMark(nil); return .resumeSkipped }
        if let explicit = env as? ExplicitPlaybackEnvironment, let token = m.token {
            guard explicit.resumePlayback(token: token) else { return .failed } // keep the mark: retry
            setMark(nil)
            return .resumed
        }
        // Audio since the pause is in the capture's timestamps. A capture that wasn't running the
        // whole time can't vouch for the gap, so listen for a moment too.
        if let start = env.captureStart(), start <= m.pausedAt + 0.25 {
            // Continuous: lastAudible covers it, and isValid already checked that.
        } else {
            guard let heard = env.probeAudible(window: timing.probeWindow) else { return .failed }
            if heard { setMark(nil); return .resumeSkipped }
        }
        guard env.pressPlayPause() else { return .failed } // keep the mark: the peer can retry
        setMark(nil)
        return .resumed
    }

    // MARK: - Helpers

    private func isValid(_ m: Mark, at t: TimeInterval) -> Bool {
        if t - m.refreshedAt >= timing.maxResumeAge { return false }
        if let explicit = env as? ExplicitPlaybackEnvironment, let token = m.token {
            // Real state: still Paused on the same track, or the user (or something) moved on.
            return explicit.isStillPaused(token: token)
        }
        // Audible after our pause (past its tail) means the user, or something else, is playing.
        if let heard = env.lastAudible(), heard > m.pausedAt + timing.graceAfterPause { return false }
        return true
    }

    private func silence(at t: TimeInterval) -> TimeInterval {
        env.lastAudible().map { t - $0 } ?? .infinity
    }

    private func setMark(_ new: Mark?) {
        mark = new
        let name = new?.peer
        if name != pausedForPeer {
            pausedForPeer = name
            onChange?(name)
        }
    }

    private func pruneAnswered(_ t: TimeInterval) {
        for (peer, ids) in answered {
            let live = ids.filter { t - $0.value.at < timing.dedupeWindow }
            // Bounded even under a flood of distinct ids.
            answered[peer] = live.count > 32 ? Dictionary(uniqueKeysWithValues: live.sorted { $0.value.at > $1.value.at }.prefix(32).map { ($0.key, $0.value) }) : live
            if answered[peer]?.isEmpty == true { answered[peer] = nil }
        }
        if answered.count > 32 { answered.removeAll() }
    }
}
