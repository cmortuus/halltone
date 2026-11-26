/// Program material often peaks at full scale, Opus decoding can overshoot slightly, and several
/// sources summed together can go well past 1.0; hard clipping at the output sounds harsh. Samples
/// below `knee` pass untouched and the rest bend smoothly toward ±1 (never reaching it).
///
/// It runs once, on the mix (see `MixBus`), not on each stream: with one source that is the same
/// result as before, with several the limiter sees what actually reaches the headphones.
public enum SoftLimiter {
    /// 0.9 linear is about −0.9 dBFS.
    public static let knee: Float = 0.9

    @inline(__always)
    public static func apply(_ v: Float) -> Float {
        let a = abs(v)
        guard a > knee else { return v }
        let range = 1 - knee
        let over = (a - knee) / range
        let shaped = knee + range * (over / (1 + over))
        return v < 0 ? -shaped : shaped
    }

    /// In place; real-time safe.
    @inline(__always)
    public static func process(_ x: UnsafeMutablePointer<Float>, count: Int) {
        var i = 0
        while i < count {
            let v = x[i]
            if abs(v) > knee { x[i] = apply(v) }
            i += 1
        }
    }
}
