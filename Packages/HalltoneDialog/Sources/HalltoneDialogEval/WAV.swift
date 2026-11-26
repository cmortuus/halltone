import Foundation

public enum WAVError: Error, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)
    public var description: String {
        switch self {
        case .malformed(let s): return "malformed WAV: \(s)"
        case .unsupported(let s): return "unsupported WAV: \(s)"
        }
    }
}

/// Minimal RIFF/WAVE support: reads 16/24/32-bit PCM and 32/64-bit float, any channel count.
public enum WAV {
    public struct Audio {
        public var sampleRate: Int
        public var channels: Int
        /// Interleaved, `frames * channels` samples in -1…1.
        public var samples: [Float]
        public var frames: Int { channels > 0 ? samples.count / channels : 0 }
    }

    public static func read(path: String) throws -> Audio {
        try parse(try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public static func parse(_ data: Data) throws -> Audio {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count >= 12, String(decoding: b[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: b[8..<12], as: UTF8.self) == "WAVE" else { throw WAVError.malformed("not RIFF/WAVE") }
        var pos = 12
        var fmtTag = 0, channels = 0, rate = 0, bits = 0
        var dataRange: Range<Int>?
        while pos + 8 <= b.count {
            let id = String(decoding: b[pos..<pos + 4], as: UTF8.self)
            var size = u32(pos + 4)
            let body = pos + 8
            if body + size > b.count { size = b.count - body }   // tolerate streamed/truncated sizes
            if id == "fmt " {
                guard size >= 16 else { throw WAVError.malformed("short fmt chunk") }
                fmtTag = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
                if fmtTag == 0xFFFE, size >= 26 { fmtTag = u16(body + 24) }   // WAVE_FORMAT_EXTENSIBLE
            } else if id == "data" {
                dataRange = body..<(body + size)
                break
            }
            pos = body + size + (size & 1)
        }
        guard let r = dataRange, channels > 0, rate > 0 else { throw WAVError.malformed("missing fmt/data") }
        let bytes = bits / 8
        let count = r.count / max(1, bytes)
        var out = [Float](repeating: 0, count: count - count % channels)
        for i in 0..<out.count {
            let o = r.lowerBound + i * bytes
            switch (fmtTag, bits) {
            case (1, 16): out[i] = Float(Int16(truncatingIfNeeded: u16(o))) / 32768
            case (1, 24):
                var v = Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16
                if v & 0x800000 != 0 { v -= 0x1000000 }
                out[i] = Float(v) / 8388608
            case (1, 32): out[i] = Float(Int32(truncatingIfNeeded: u32(o))) / 2147483648
            case (3, 32): out[i] = Float(bitPattern: UInt32(truncatingIfNeeded: u32(o)))
            case (3, 64):
                let lo = UInt64(u32(o)), hi = UInt64(u32(o + 4))
                out[i] = Float(Double(bitPattern: lo | hi << 32))
            default: throw WAVError.unsupported("format \(fmtTag), \(bits) bits")
            }
        }
        return Audio(sampleRate: rate, channels: channels, samples: out)
    }

    /// Writes 16-bit PCM.
    public static func write16(path: String, sampleRate: Int, channels: Int, samples: [Float]) throws {
        var d = Data()
        func put32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func put16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let dataBytes = samples.count * 2
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + dataBytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16)
        put16(1); put16(channels); put32(sampleRate); put32(sampleRate * channels * 2); put16(channels * 2); put16(16)
        d.append(contentsOf: Array("data".utf8)); put32(dataBytes)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let v = samples[i].isFinite ? samples[i] : 0
            pcm[i] = Int16(max(-32768, min(32767, (v * 32768).rounded())))
        }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: URL(fileURLWithPath: path))
    }

    /// Converts to 48 kHz interleaved stereo Float32 (mono is duplicated, extra channels dropped).
    public static func toStereo48k(_ a: Audio) -> [Float] {
        let n = a.frames
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            l[i] = a.samples[i * a.channels]
            r[i] = a.channels > 1 ? a.samples[i * a.channels + 1] : l[i]
        }
        if a.sampleRate != 48_000 {
            l = Resampler.resample(l, from: a.sampleRate, to: 48_000)
            r = Resampler.resample(r, from: a.sampleRate, to: 48_000)
        }
        var out = [Float](repeating: 0, count: l.count * 2)
        for i in 0..<l.count { out[2 * i] = l[i]; out[2 * i + 1] = r[i] }
        return out
    }
}

/// Offline windowed-sinc resampler (quality over speed; for the CLI and tests only).
public enum Resampler {
    public static func resample(_ x: [Float], from: Int, to: Int, halfWidth: Int = 16) -> [Float] {
        guard from != to, !x.isEmpty else { return x }
        let ratio = Double(to) / Double(from)
        let outCount = Int((Double(x.count) * ratio).rounded(.down))
        let cutoff = min(1.0, ratio)           // low-pass at the lower of the two Nyquists
        var out = [Float](repeating: 0, count: outCount)
        let hw = Double(halfWidth)
        for n in 0..<outCount {
            let t = Double(n) / ratio
            let c = Int(t.rounded(.down))
            var acc = 0.0
            var k = c - halfWidth + 1
            while k <= c + halfWidth {
                if k >= 0 && k < x.count {
                    let d = t - Double(k)
                    let arg = Double.pi * d * cutoff
                    let s = abs(d) < 1e-9 ? cutoff : sin(arg) / (Double.pi * d)
                    let w = 0.5 + 0.5 * cos(Double.pi * d / hw)
                    acc += Double(x[k]) * s * w
                }
                k += 1
            }
            out[n] = Float(acc)
        }
        return out
    }
}
