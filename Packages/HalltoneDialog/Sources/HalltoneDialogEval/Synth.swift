import Foundation

/// Deterministic xorshift64* generator so synthetic test signals are reproducible.
public struct SplitRNG {
    var state: UInt64
    public init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    public mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
    /// Uniform in -1…1.
    public mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 52) - 1 }
}

/// Non-speech test signals, all 48 kHz interleaved stereo.
public enum SyntheticAudio {
    public static let rate = 48_000

    public static func sine(seconds: Double, hz: Double, amplitude: Float = 0.3) -> [Float] {
        let n = Int(seconds * Double(rate))
        var out = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let v = amplitude * Float(sin(2 * Double.pi * hz * Double(i) / Double(rate)))
            out[2 * i] = v; out[2 * i + 1] = v
        }
        return out
    }

    /// Pink-ish noise (Voss-McCartney-style 1/f via Paul Kellet's filter), identical in both channels.
    public static func pinkNoise(seconds: Double, amplitude: Float = 0.1, seed: UInt64 = 1) -> [Float] {
        let n = Int(seconds * Double(rate))
        var rng = SplitRNG(seed: seed)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        var out = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let w = rng.uniform()
            b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759
            b2 = 0.96900 * b2 + w * 0.1538520; b3 = 0.86650 * b3 + w * 0.3104856
            b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980
            let p = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.11
            b6 = w * 0.115926
            out[2 * i] = Float(p) * amplitude; out[2 * i + 1] = Float(p) * amplitude
        }
        return out
    }

    /// Wide-stereo "music": a changing chord of harmonic-rich notes (different phase and slight
    /// detune per channel, so the channels are largely decorrelated), a slow tremolo, and
    /// independent noise "percussion" bursts in each channel. Dense in the speech band on purpose.
    public static func wideMusic(seconds: Double, amplitude: Float = 0.15, seed: UInt64 = 7) -> [Float] {
        let n = Int(seconds * Double(rate))
        var rng = SplitRNG(seed: seed)
        let chords: [[Double]] = [[220, 277.18, 329.63], [196, 246.94, 293.66], [174.61, 220, 261.63], [196, 246.94, 392]]
        var out = [Float](repeating: 0, count: n * 2)
        // 12 partials per channel (3 notes × 4 harmonics) as rotating phasors: no sin() per sample.
        var cL = [Double](repeating: 0, count: 12), sL = cL, cR = cL, sR = cL
        for k in 0..<12 {
            let a = rng.uniform() * .pi, b = rng.uniform() * .pi
            cL[k] = cos(a); sL[k] = sin(a); cR[k] = cos(b); sR[k] = sin(b)
        }
        var rotCL = cL, rotSL = sL, rotCR = cL, rotSR = sL   // per-partial rotation increments (set per chord)
        // each partial gets its own detune so the channels decorrelate independently per partial
        var detune = [Double](repeating: 0, count: 12)
        for k in 0..<12 { detune[k] = 0.002 + 0.006 * abs(rng.uniform()) }
        var lpL = 0.0, lpR = 0.0
        let beat = rate / 4
        var envNoise = 0.0
        var chordIndex = -1
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            let ci = Int(t / 2) % chords.count
            if ci != chordIndex {
                chordIndex = ci
                for (ni, f) in chords[ci].enumerated() {
                    for h in 1...4 {
                        let k = ni * 4 + h - 1
                        let wl = 2 * Double.pi * f * Double(h) * (1 + detune[k]) / Double(rate)
                        let wr = 2 * Double.pi * f * Double(h) * (1 - detune[k]) / Double(rate)
                        rotCL[k] = cos(wl); rotSL[k] = sin(wl); rotCR[k] = cos(wr); rotSR[k] = sin(wr)
                    }
                }
            }
            var l = 0.0, r = 0.0
            for k in 0..<12 {
                let amp = 1.0 / Double(k % 4 + 1)
                l += amp * sL[k]; r += amp * sR[k]
                let nc = cL[k] * rotCL[k] - sL[k] * rotSL[k]
                sL[k] = sL[k] * rotCL[k] + cL[k] * rotSL[k]; cL[k] = nc
                let mc = cR[k] * rotCR[k] - sR[k] * rotSR[k]
                sR[k] = sR[k] * rotCR[k] + cR[k] * rotSR[k]; cR[k] = mc
            }
            if i & 4095 == 0 {   // keep phasors on the unit circle
                for k in 0..<12 {
                    let ml = (cL[k] * cL[k] + sL[k] * sL[k]).squareRoot(), mr = (cR[k] * cR[k] + sR[k] * sR[k]).squareRoot()
                    cL[k] /= ml; sL[k] /= ml; cR[k] /= mr; sR[k] /= mr
                }
            }
            let trem = 0.75 + 0.25 * sin(2 * .pi * 0.7 * t)
            if i % beat == 0 { envNoise = 1 }
            envNoise *= 0.9995
            lpL += 0.4 * (rng.uniform() - lpL); lpR += 0.4 * (rng.uniform() - lpR)
            out[2 * i] = amplitude * Float((l * trem / 8) + lpL * envNoise * 0.5)
            out[2 * i + 1] = amplitude * Float((r * trem / 8) + lpR * envNoise * 0.5)
        }
        return out
    }
}

/// Speech from the platform's TTS (`say` on macOS, `espeak-ng` on Linux). Nothing is bundled:
/// tests and the demo generator synthesize at run time and skip when no engine exists.
public enum SpeechSynth {
    public static func enginePath() -> String? {
        for p in ["/usr/bin/say", "/usr/bin/espeak-ng", "/usr/local/bin/espeak-ng", "/opt/homebrew/bin/espeak-ng"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    public static var isAvailable: Bool { enginePath() != nil }

    /// Returns mono 48 kHz Float32 speech, or nil when no engine is installed / it fails.
    public static func synthesize(_ text: String, voice: String? = nil) -> [Float]? {
        guard let engine = enginePath() else { return nil }
        let file = NSTemporaryDirectory() + "halltone-tts-\(UUID().uuidString).wav"
        defer { try? FileManager.default.removeItem(atPath: file) }
        var args: [String]
        if engine.hasSuffix("say") {
            args = ["-o", file, "--data-format=LEI16@48000"]
            if let v = voice { args += ["-v", v] }
            args.append(text)
        } else {
            args = ["-w", file]
            if let v = voice { args += ["-v", v] }
            args.append(text)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: engine)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let audio = try? WAV.read(path: file), audio.frames > 0 else { return nil }
        let stereo = WAV.toStereo48k(audio)
        var mono = [Float](repeating: 0, count: stereo.count / 2)
        for i in 0..<mono.count { mono[i] = stereo[2 * i] }
        return mono
    }

    /// Time range (seconds) where a speech clip is above `thresholdDBFS` in 10 ms RMS frames.
    public static func activeRange(_ x: [Float], thresholdDBFS: Double = -50) -> (start: Double, end: Double)? {
        let step = 480
        var first: Int?, last: Int?
        var i = 0
        while i + step <= x.count {
            var s = 0.0
            for k in i..<i + step { s += Double(x[k]) * Double(x[k]) }
            if 10 * log10(s / Double(step) + 1e-20) > thresholdDBFS {
                if first == nil { first = i }
                last = i + step
            }
            i += step
        }
        guard let f = first, let l = last else { return nil }
        return (Double(f) / 48_000, Double(l) / 48_000)
    }
}

public struct DemoMix {
    public var samples: [Float]      // 48 kHz interleaved stereo
    public var labels: [Label]       // one per spoken line
}

/// Builds a game-like clip: speech lines (panned center) placed at fixed times over wide
/// music-like noise, with the lines' active ranges as ground-truth labels. Returns nil when no
/// TTS engine is available.
public func makeDemoMix(lines: [String], gaps: [Double], leadIn: Double = 3, tail: Double = 3,
                        speechGain: Float = 0.5, musicGain: Float = 0.15, voices: [String?] = []) -> DemoMix? {
    var clips: [[Float]] = []
    for (i, line) in lines.enumerated() {
        guard let c = SpeechSynth.synthesize(line, voice: i < voices.count ? voices[i] : nil) else { return nil }
        clips.append(c)
    }
    var peak: Float = 0.0001
    for c in clips { for v in c { peak = max(peak, abs(v)) } }
    let norm = speechGain / peak
    var t = leadIn
    var placed: [(Int, [Float])] = []
    var labels: [Label] = []
    for (i, c) in clips.enumerated() {
        guard let r = SpeechSynth.activeRange(c) else { continue }
        placed.append((Int(t * 48_000), c))
        labels.append(Label(start: t + r.start, end: t + r.end, text: "speech"))
        t += Double(c.count) / 48_000 + (i < gaps.count ? gaps[i] : 1)
    }
    let total = t + tail
    var mix = SyntheticAudio.wideMusic(seconds: total, amplitude: musicGain)
    for (off, c) in placed {
        for k in 0..<c.count {
            let idx = 2 * (off + k)
            if idx + 1 < mix.count { mix[idx] += c[k] * norm; mix[idx + 1] += c[k] * norm }
        }
    }
    return DemoMix(samples: mix, labels: labels)
}
