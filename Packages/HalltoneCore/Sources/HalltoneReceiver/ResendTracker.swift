import Foundation
import HalltoneCore

/// Tracks holes in the packet stream (by `samplePos`) and decides when to ask the Mac to resend them.
///
/// A new hole isn't requested at once: packets that were only reordered arrive by themselves a few
/// ms later, and asking for them wastes bandwidth (about 30 % at 2.5 ms frames with 10 ms of
/// jitter). A hole is requested once it has stayed open for the reorder window, which starts at
/// max(5 ms, 2 frames) and widens when packets keep arriving just before it runs out. The window
/// never exceeds a cap the caller derives from the jitter buffer's target, so a requested frame can
/// still be played. Pure state with the clock passed in, so it's unit-testable.
struct ResendTracker {
    struct Hole { var noticed: TimeInterval; var requested: TimeInterval?; var tries = 0 }

    let frame: UInt64
    private(set) var holes: [UInt64: Hole] = [:]
    private var newest: UInt64?
    private(set) var window: TimeInterval
    private var lastGrow: TimeInterval = 0

    init(frameSamples: Int) {
        frame = UInt64(frameSamples)
        window = Self.baseWindow(frameSamples: frameSamples)
    }

    static func baseWindow(frameSamples: Int) -> TimeInterval { max(0.005, 2 * Double(frameSamples) / Constants.sampleRate) }
    var baseWindow: TimeInterval { Self.baseWindow(frameSamples: Int(frame)) }

    /// A packet arrived. Returns true if it filled a hole.
    mutating func received(pos: UInt64, at t: TimeInterval, cap: TimeInterval) -> Bool {
        guard let top = newest else { newest = pos; return false }
        if pos <= top {
            // Late, reordered or a retransmission.
            guard let h = holes.removeValue(forKey: pos) else { return false }
            // Arrived by itself, before we asked, near the end of the window: the window is about
            // as long as this network's reordering, so widen it. (Loss never gets here.)
            if h.requested == nil, t - h.noticed > 0.7 * window {
                window = max(baseWindow, window * 1.5, (t - h.noticed) * 1.3)
                lastGrow = t
            }
            return true
        }
        newest = pos
        let gapFrames = (pos - top) / frame
        // A hole of more than ~0.5-1 s is an outage or a stream jump, not loss worth chasing.
        if gapFrames > 1, gapFrames <= max(100, 24_000 / frame) {
            var p = top + frame
            while p < pos { holes[p] = Hole(noticed: t); p += frame }
        }
        return false
    }

    /// The window in force now. The cap (a share of the jitter buffer's target) overrides even the
    /// base: with a small buffer a delayed request would miss its playout time, so down to one
    /// frame the window shrinks with it.
    func effectiveWindow(cap: TimeInterval) -> TimeInterval { max(frameDuration, min(window, cap)) }
    var frameDuration: TimeInterval { Double(frame) / Constants.sampleRate }

    /// Holes whose window has run out: mark them requested and return their positions.
    mutating func due(at t: TimeInterval, cap: TimeInterval, limit: Int) -> [UInt64] {
        let w = effectiveWindow(cap: cap)
        var ask = holes.compactMap { $0.value.requested == nil && t - $0.value.noticed >= w ? $0.key : nil }.sorted()
        if ask.count > limit { ask.removeSubrange(limit...) }
        for p in ask { holes[p]?.requested = t; holes[p]?.tries = 1 }
        return ask
    }

    /// Frames still missing 150 ms after their request get one more request; everything is
    /// forgotten 2 s after it was noticed or requested.
    mutating func retries(at t: TimeInterval, limit: Int) -> [UInt64] {
        var again: [UInt64] = []
        for (p, h) in holes {
            if t - (h.requested ?? h.noticed) > 2 { holes.removeValue(forKey: p); continue }
            if let r = h.requested, h.tries < 2, t - r > 0.15, again.count < limit {
                holes[p]?.tries += 1; again.append(p)
            }
        }
        return again.sorted()
    }

    /// Called every ~250 ms: the window relaxes back once the reordering has stopped.
    mutating func relax(at t: TimeInterval) {
        if t - lastGrow > 3 { window = max(baseWindow, window * 0.9) }
    }
}
