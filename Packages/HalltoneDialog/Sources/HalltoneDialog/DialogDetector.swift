#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import CFVAD

/// Tunable thresholds for ``DialogDetector``. Everything the detector decides is controlled here.
public struct DialogConfig: Equatable, Sendable {
    /// How hard the center extraction pushes down wide (side-heavy) content. The mid channel's
    /// power is reduced by `centerSideScale ×` the side channel's power (a Wiener-style
    /// "mid minus a scaled side estimate"). 0 disables center extraction; 1 assumes wide music
    /// has as much mid power as side power. The default of 2 over-subtracts on purpose: wide
    /// music rarely has its mid power equal to its side power frame by frame, and dialog (which
    /// is centered) has almost no side power, so it passes untouched.
    public var centerSideScale: Double = 2.0
    /// Smoothing of the mid/side power estimates, per 10 ms block (0 = none, →1 = very slow).
    public var centerSmoothing: Double = 0.5
    /// WebRTC VAD aggressiveness, 0 (permissive) … 3 (most aggressive).
    public var vadMode: Int = 3
    /// Gate: the fraction of mid power in `speechBandLowHz`…`speechBandHighHz` must be at least
    /// this. Measured on power smoothed over `bandSmoothing`, since single 10 ms frames of speech
    /// (fricatives, low male fundamentals) swing widely. Real voices put much of their energy
    /// below 300 Hz (measured medians: 0.24–0.57 across six macOS voices), so this is only a
    /// veto for bass-heavy (explosions, engines) and hissy content, not a speech detector.
    public var speechBandRatioMin: Double = 0.15
    /// Smoothing of the band-energy ratio per 10 ms block (0 = none, →1 = very slow).
    public var bandSmoothing: Double = 0.8
    /// Gate: over the last `startWindowMs` the speech-band (300–3400 Hz) level, in 10 ms blocks,
    /// must have moved by at least this many dB (max − min). Speech is syllabic and always dips
    /// between words and syllables (measured: ≥ 10 dB for nearly all speech frames, 20–35 dB
    /// typical); steady tones, hiss, hum and pad-like music stay within 3–7 dB, yet a bare VAD
    /// happily calls them speech. Measured in the speech band so that low-frequency rumble
    /// (whose 10 ms power swings wildly) cannot fake modulation. 0 disables the gate.
    public var minModulationDB: Double = 8
    public var speechBandLowHz: Double = 300
    public var speechBandHighHz: Double = 3400
    /// Gate: the extracted center's RMS level for a 10 ms block must be at least this (dBFS).
    public var minLevelDBFS: Double = -45
    /// Dialog starts once this much speech is seen …
    public var startSpeechMs: Int = 250
    /// … within this trailing window.
    public var startWindowMs: Int = 400
    /// Dialog ends after this long with no speech.
    public var endSilenceMs: Int = 1200

    public init() {}

    /// Length of one analysis frame. Fixed: libfvad accepts 10, 20 or 30 ms at 16 kHz.
    public static let frameMs = 10
    /// The only supported input format: 48 kHz interleaved stereo Float32.
    public static let sampleRate = 48_000
}

/// A change in dialog state. Times are seconds since the first sample given to the detector.
public enum DialogEvent: Equatable, Sendable {
    /// Dialog began. `time` is the start of the first speech frame in the qualifying window;
    /// `detectedAt` is the stream time at which the detector could say so (≥ `time`).
    case started(time: Double, detectedAt: Double)
    /// Dialog ended. `time` is the end of the last speech frame; `detectedAt` is when the
    /// hysteresis released (≈ `endSilenceMs` later).
    case ended(time: Double, detectedAt: Double)

    public var time: Double {
        switch self {
        case .started(let t, _), .ended(let t, _): return t
        }
    }

    public var detectedAt: Double {
        switch self {
        case .started(_, let t), .ended(_, let t): return t
        }
    }

    public var isStart: Bool {
        if case .started = self { return true }
        return false
    }
}

/// Real-time dialog detector for 48 kHz interleaved stereo Float32 game audio.
///
/// Pipeline: center extraction (mid with side-proportional power subtracted) → 3:1 decimation to
/// 16 kHz → libfvad per 10 ms frame, gated by a speech-band energy ratio and a minimum level →
/// hysteresis. Nothing allocates after `init`, except the returned `[DialogEvent]` on the rare
/// calls that actually carry an event; use ``process(_:frames:onEvent:)`` to avoid even that.
///
/// Not thread-safe: call from one thread (typically the audio thread) at a time.
public final class DialogDetector {
    public let config: DialogConfig
    public private(set) var isDialogActive = false

    // 48 kHz block = 10 ms
    private static let block = DialogConfig.sampleRate * DialogConfig.frameMs / 1000   // 480
    private static let outBlock = block / 3                                             // 160
    private static let taps = 48

    private let vad: OpaquePointer
    private let firCoeffs: UnsafeMutablePointer<Float>      // taps, symmetric low-pass
    private let history: UnsafeMutablePointer<Float>        // 2 × taps, circular double-write
    private var histPos = 0
    private let decimated: UnsafeMutablePointer<Float>      // outBlock, un-gained mid at 16 kHz
    private let pcm: UnsafeMutablePointer<Int16>            // outBlock
    private var blockFill = 0                               // 48 kHz frames in current block
    private var outFill = 0
    private var phase = 0                                   // decimation phase 0..<3

    // power accumulators for the current block
    private var accMid = 0.0, accSide = 0.0, accBand = 0.0
    // smoothed estimates + gain ramp
    private var smMid = 0.0, smSide = 0.0, smBandMid = 0.0, smBand = 0.0
    private var prevGain = 1.0

    // band-pass biquads (transposed direct form II): HP + 2×LP (Butterworth)
    private struct Biquad {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1 = 0.0, z2 = 0.0
    }
    private var hp = Biquad(), lp1 = Biquad(), lp2 = Biquad()

    // hysteresis
    private let ring: UnsafeMutablePointer<UInt8>
    private let ringLen: Int
    private let levelRing: UnsafeMutablePointer<Float>   // 10 ms speech-band level (dB), same length as ring
    private var levelFill = 0
    private let modulationMin: Double
    private var ringPos = 0
    private var ringCount = 0
    private let startFrames: Int
    private let endFrames: Int
    private var frameIndex = 0                              // 10 ms frames completed
    private var sinceSpeech = 0                             // frames since last speech (active)
    private var lastSpeechFrame = -1

    private let minLevelPower: Double
    private let sideScale: Double
    private let smoothing: Double
    private let bandSmoothing: Double
    private let bandMin: Double

    public init(config: DialogConfig = DialogConfig()) {
        self.config = config
        vad = fvad_new()
        _ = fvad_set_mode(vad, Int32(max(0, min(3, config.vadMode))))
        _ = fvad_set_sample_rate(vad, 16_000)

        firCoeffs = .allocate(capacity: Self.taps)
        history = .allocate(capacity: Self.taps * 2)
        history.initialize(repeating: 0, count: Self.taps * 2)
        decimated = .allocate(capacity: Self.outBlock)
        decimated.initialize(repeating: 0, count: Self.outBlock)
        pcm = .allocate(capacity: Self.outBlock)
        pcm.initialize(repeating: 0, count: Self.outBlock)

        // Hann-windowed sinc low-pass, 7 kHz cutoff at 48 kHz (anti-alias before 3:1).
        let fc = 7_000.0 / 48_000.0
        var sum = 0.0
        var tmp = [Double](repeating: 0, count: Self.taps)
        let mid = Double(Self.taps - 1) / 2
        for n in 0..<Self.taps {
            let x = Double(n) - mid
            let sinc = x == 0 ? 2 * fc : sin(2 * Double.pi * fc * x) / (Double.pi * x)
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(Self.taps - 1))
            tmp[n] = sinc * w
            sum += tmp[n]
        }
        for n in 0..<Self.taps { firCoeffs[n] = Float(tmp[n] / sum) }

        let frameMs = DialogConfig.frameMs
        ringLen = max(1, config.startWindowMs / frameMs)
        ring = .allocate(capacity: ringLen)
        ring.initialize(repeating: 0, count: ringLen)
        levelRing = .allocate(capacity: ringLen)
        levelRing.initialize(repeating: 0, count: ringLen)
        modulationMin = config.minModulationDB
        startFrames = max(1, (config.startSpeechMs + frameMs - 1) / frameMs)
        endFrames = max(1, (config.endSilenceMs + frameMs - 1) / frameMs)

        minLevelPower = pow(10, config.minLevelDBFS / 10)
        sideScale = max(0, config.centerSideScale)
        smoothing = min(0.99, max(0, config.centerSmoothing))
        bandMin = config.speechBandRatioMin
        bandSmoothing = min(0.99, max(0, config.bandSmoothing))

        let fs = Double(DialogConfig.sampleRate)
        hp = Self.butterworth(highpass: true, cutoff: config.speechBandLowHz, fs: fs)
        lp1 = Self.butterworth(highpass: false, cutoff: config.speechBandHighHz, fs: fs, q: 0.5411961)
        lp2 = Self.butterworth(highpass: false, cutoff: config.speechBandHighHz, fs: fs, q: 1.3065630)
    }

    deinit {
        fvad_free(vad)
        firCoeffs.deallocate()
        history.deallocate()
        decimated.deallocate()
        pcm.deallocate()
        ring.deallocate()
        levelRing.deallocate()
    }

    /// Forget all audio history and return to "no dialog". Does not emit an `.ended` event.
    public func reset() {
        fvad_reset(vad)
        // fvad_reset also puts the mode and sample rate back to their defaults
        _ = fvad_set_mode(vad, Int32(max(0, min(3, config.vadMode))))
        _ = fvad_set_sample_rate(vad, 16_000)
        history.update(repeating: 0, count: Self.taps * 2)
        histPos = 0; blockFill = 0; outFill = 0; phase = 0
        accMid = 0; accSide = 0; accBand = 0
        smMid = 0; smSide = 0; smBandMid = 0; smBand = 0; prevGain = 1
        hp.z1 = 0; hp.z2 = 0; lp1.z1 = 0; lp1.z2 = 0; lp2.z1 = 0; lp2.z2 = 0
        ring.update(repeating: 0, count: ringLen)
        ringPos = 0; ringCount = 0; levelFill = 0
        frameIndex = 0; sinceSpeech = 0; lastSpeechFrame = -1
        isDialogActive = false
    }

    /// Feed `frames` frames of 48 kHz interleaved stereo Float32. Returns the events (if any) that
    /// completed within this call. The returned array is empty — and allocation-free — when nothing happened.
    public func process(_ interleaved: UnsafePointer<Float>, frames: Int) -> [DialogEvent] {
        var events: [DialogEvent] = []
        process(interleaved, frames: frames) { events.append($0) }
        return events
    }

    /// Allocation-free variant: `onEvent` is called synchronously for each event.
    public func process(_ interleaved: UnsafePointer<Float>, frames: Int, onEvent: (DialogEvent) -> Void) {
        // Hoist hot state into locals: avoids per-sample class exclusivity checks.
        var blockFill = self.blockFill
        var outFill = self.outFill
        var phase = self.phase
        var histPos = self.histPos
        var accMid = self.accMid, accSide = self.accSide, accBand = self.accBand
        var hp = self.hp, lp1 = self.lp1, lp2 = self.lp2
        let taps = Self.taps
        let block = Self.block
        let fir = firCoeffs
        let hist = history
        let dec = decimated

        var i = 0
        while i < frames {
            let lf = interleaved[2 * i], rf = interleaved[2 * i + 1]
            let l = lf.isFinite ? Double(lf) : 0, r = rf.isFinite ? Double(rf) : 0
            i += 1
            let m = 0.5 * (l + r), s = 0.5 * (l - r)
            accMid += m * m
            accSide += s * s

            // speech-band energy (on mid)
            var y = hp.b0 * m + hp.z1
            hp.z1 = hp.b1 * m - hp.a1 * y + hp.z2
            hp.z2 = hp.b2 * m - hp.a2 * y
            var x = y
            y = lp1.b0 * x + lp1.z1
            lp1.z1 = lp1.b1 * x - lp1.a1 * y + lp1.z2
            lp1.z2 = lp1.b2 * x - lp1.a2 * y
            x = y
            y = lp2.b0 * x + lp2.z1
            lp2.z1 = lp2.b1 * x - lp2.a1 * y + lp2.z2
            lp2.z2 = lp2.b2 * x - lp2.a2 * y
            accBand += y * y

            // decimating FIR: history is double-written so the window is always contiguous
            let mf = Float(m)
            hist[histPos] = mf
            hist[histPos + taps] = mf
            histPos += 1
            if histPos == taps { histPos = 0 }
            if phase == 0 {
                // newest sample is at histPos-1+taps; window = hist[histPos ..< histPos+taps], oldest first
                var acc: Float = 0
                let w = hist + histPos
                for k in 0..<taps { acc += fir[k] * w[taps - 1 - k] }
                dec[outFill] = acc
                outFill += 1
            }
            phase += 1
            if phase == 3 { phase = 0 }

            blockFill += 1
            if blockFill == block {
                let mid = accMid / Double(block)
                let side = accSide / Double(block)
                let band = accBand / Double(block)
                accMid = 0; accSide = 0; accBand = 0
                blockFill = 0
                outFill = 0
                finishBlock(midPower: mid, sidePower: side, bandPower: band, onEvent: onEvent)
            }
        }

        self.blockFill = blockFill
        self.outFill = outFill
        self.phase = phase
        self.histPos = histPos
        self.accMid = accMid; self.accSide = accSide; self.accBand = accBand
        self.hp = hp; self.lp1 = lp1; self.lp2 = lp2
    }

    // MARK: - per-10 ms-block decision

    private func finishBlock(midPower: Double, sidePower: Double, bandPower: Double,
                             onEvent: (DialogEvent) -> Void) {
        // Non-finite input (NaN/inf from a broken source) counts as silence rather than poisoning state.
        guard midPower.isFinite, sidePower.isFinite, bandPower.isFinite else {
            prevGain = 1
            levelRing[ringPos] = -90
            if levelFill < ringLen { levelFill += 1 }
            advance(speech: false, onEvent: onEvent)
            return
        }
        // Center extraction: smoothed mid power minus scaled side power, as a gain on mid.
        smMid = smoothing * smMid + (1 - smoothing) * midPower
        smSide = smoothing * smSide + (1 - smoothing) * sidePower
        var gain = 1.0
        if smMid > 1e-14 {
            let c = 1 - sideScale * smSide / smMid
            gain = c > 0 ? c.squareRoot() : 0
        }

        let centerPower = midPower * gain * gain
        smBandMid = bandSmoothing * smBandMid + (1 - bandSmoothing) * midPower
        smBand = bandSmoothing * smBand + (1 - bandSmoothing) * bandPower
        let ratio = smBandMid > 1e-14 ? smBand / smBandMid : 0
        let loud = centerPower >= minLevelPower

        // The VAD only sees blocks that pass the level gate (silence is the common case and
        // there is nothing to classify); the band gate then vetoes its decision.
        var vadSays = false
        if loud {
            // gain ramps linearly across the block to avoid clicks at block edges
            let n = Self.outBlock
            let g0 = Float(prevGain), dg = Float(gain - prevGain) / Float(n)
            for k in 0..<n {
                let v = decimated[k] * (g0 + dg * Float(k + 1)) * 32768
                pcm[k] = Int16(max(-32768, min(32767, v)))
            }
            vadSays = fvad_process(vad, pcm, n) == 1
        }
        // speech-band level history for the modulation gate (written at the same slot `advance` will use)
        levelRing[ringPos] = Float(max(-90, 10 * log10(bandPower + 1e-12)))
        if levelFill < ringLen { levelFill += 1 }
        var lo = levelRing[0], hi = lo
        for k in 1..<max(1, levelFill) {
            let v = levelRing[k]
            lo = min(lo, v); hi = max(hi, v)
        }
        let modulated = modulationMin <= 0 || Double(hi - lo) >= modulationMin
        let speech = vadSays && ratio >= bandMin && modulated
        prevGain = gain

        advance(speech: speech, onEvent: onEvent)
    }

    private func advance(speech: Bool, onEvent: (DialogEvent) -> Void) {
        let dt = Double(DialogConfig.frameMs) / 1000
        // sliding window of recent speech flags
        ringCount -= Int(ring[ringPos])
        ring[ringPos] = speech ? 1 : 0
        ringCount += speech ? 1 : 0
        ringPos += 1
        if ringPos == ringLen { ringPos = 0 }

        let thisFrame = frameIndex
        frameIndex += 1
        if speech { lastSpeechFrame = thisFrame }

        if !isDialogActive {
            if ringCount >= startFrames {
                // onset = oldest flagged frame still in the window
                var first = thisFrame
                var p = ringPos   // ringPos now points at the oldest entry
                for k in 0..<ringLen {
                    if ring[p] == 1 { first = thisFrame - (ringLen - 1 - k); break }
                    p += 1
                    if p == ringLen { p = 0 }
                }
                isDialogActive = true
                sinceSpeech = 0
                onEvent(.started(time: Double(max(0, first)) * dt, detectedAt: Double(thisFrame + 1) * dt))
            }
        } else {
            if speech {
                sinceSpeech = 0
            } else {
                sinceSpeech += 1
                if sinceSpeech >= endFrames {
                    isDialogActive = false
                    onEvent(.ended(time: Double(lastSpeechFrame + 1) * dt, detectedAt: Double(thisFrame + 1) * dt))
                }
            }
        }
    }

    // MARK: - filter design (RBJ cookbook)

    private static func butterworth(highpass: Bool, cutoff: Double, fs: Double, q: Double = 0.70710678) -> Biquad {
        let w0 = 2 * Double.pi * min(cutoff, fs * 0.49) / fs
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        let a0 = 1 + alpha
        var bq = Biquad()
        if highpass {
            bq.b0 = (1 + c) / 2 / a0
            bq.b1 = -(1 + c) / a0
            bq.b2 = (1 + c) / 2 / a0
        } else {
            bq.b0 = (1 - c) / 2 / a0
            bq.b1 = (1 - c) / a0
            bq.b2 = (1 - c) / 2 / a0
        }
        bq.a1 = -2 * c / a0
        bq.a2 = (1 - alpha) / a0
        return bq
    }
}
