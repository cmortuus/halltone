import Foundation

/// Encodes one frame of interleaved stereo Float32 at 48 kHz.
public protocol AudioEncoder: AnyObject {
    var codec: CodecID { get }
    var frameSamples: Int { get }
    var maxPayloadBytes: Int { get }
    /// `pcm` holds frameSamples * channels floats. Returns the number of bytes written to `out`
    /// (capacity maxPayloadBytes), or 0 on failure.
    func encode(_ pcm: UnsafePointer<Float>, into out: UnsafeMutablePointer<UInt8>) -> Int
}

/// Decodes one frame into interleaved stereo Float32 at 48 kHz.
public protocol AudioDecoder: AnyObject {
    var codec: CodecID { get }
    var frameSamples: Int { get }
    /// Writes frameSamples * channels floats. Returns false (and writes silence) on a bad payload.
    func decode(_ payload: UnsafeRawBufferPointer, into pcm: UnsafeMutablePointer<Float>) -> Bool
    /// Conceals a lost frame from decoder history.
    func conceal(into pcm: UnsafeMutablePointer<Float>)
    /// Recovers a lost frame from the *following* packet's in-band FEC, if the codec supports it.
    func decodeFEC(nextPayload: UnsafeRawBufferPointer, into pcm: UnsafeMutablePointer<Float>) -> Bool
    func reset()
}

public enum CodecFactory {
    public static func frameSamples(for codec: CodecID) -> Int {
        switch codec {
        case .pcm16: return Constants.pcmFrameSamples
        case .opus: return Constants.opusFrameSamples
        }
    }

    public static func makeDecoder(for codec: CodecID, frameSamples: Int) -> AudioDecoder? {
        switch codec {
        case .pcm16: return PCM16Decoder(frameSamples: frameSamples)
        case .opus: return try? OpusDecoder(frameSamples: frameSamples)
        }
    }
}

// MARK: - PCM16 (interleaved stereo, big-endian)

public final class PCM16Encoder: AudioEncoder {
    public let codec: CodecID = .pcm16
    public let frameSamples: Int
    public var maxPayloadBytes: Int { frameSamples * Constants.channels * 2 }

    public init(frameSamples: Int = Constants.pcmFrameSamples) { self.frameSamples = frameSamples }

    public func encode(_ pcm: UnsafePointer<Float>, into out: UnsafeMutablePointer<UInt8>) -> Int {
        let n = frameSamples * Constants.channels
        var o = 0
        for i in 0..<n {
            let v = max(-1, min(1, pcm[i]))
            let s = Int16((v * 32767).rounded())
            let u = UInt16(bitPattern: s)
            out[o] = UInt8(u >> 8); out[o + 1] = UInt8(u & 0xff)
            o += 2
        }
        return o
    }
}

public final class PCM16Decoder: AudioDecoder {
    public let codec: CodecID = .pcm16
    public let frameSamples: Int
    private let count: Int
    private var last: [Float]
    private var haveLast = false

    public init(frameSamples: Int = Constants.pcmFrameSamples) {
        self.frameSamples = frameSamples
        count = frameSamples * Constants.channels
        last = [Float](repeating: 0, count: count)
    }

    public func decode(_ payload: UnsafeRawBufferPointer, into pcm: UnsafeMutablePointer<Float>) -> Bool {
        guard payload.count == count * 2, let base = payload.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            pcm.update(repeating: 0, count: count)
            haveLast = false
            return false
        }
        for i in 0..<count {
            let u = UInt16(base[2 * i]) << 8 | UInt16(base[2 * i + 1])
            let v = Float(Int16(bitPattern: u)) / 32768
            pcm[i] = v
            last[i] = v
        }
        haveLast = true
        return true
    }

    /// Fades the previous frame out to silence over this frame. Repeated conceals converge to silence.
    public func conceal(into pcm: UnsafeMutablePointer<Float>) {
        guard haveLast else { pcm.update(repeating: 0, count: count); return }
        let frames = frameSamples
        for f in 0..<frames {
            let g = 1 - Float(f + 1) / Float(frames)
            for c in 0..<Constants.channels {
                let i = f * Constants.channels + c
                pcm[i] = last[i] * g
            }
        }
        for i in 0..<count { last[i] = pcm[i] }
    }

    public func decodeFEC(nextPayload: UnsafeRawBufferPointer, into pcm: UnsafeMutablePointer<Float>) -> Bool { false }

    public func reset() { haveLast = false; last = [Float](repeating: 0, count: count) }
}
