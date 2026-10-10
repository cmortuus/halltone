import Foundation
import COpus
import COpusShim

public enum OpusError: Error, CustomStringConvertible {
    case create(Int32)
    case badFrameSize(Int)
    public var description: String {
        switch self {
        case .create(let c): return "opus create failed: \(String(cString: opus_strerror(c)))"
        case .badFrameSize(let n): return "unsupported Opus frame size \(n)"
        }
    }
}

/// Opus, 48 kHz stereo, 10 ms frames, 128 kbps VBR, in-band FEC enabled (effective only in
/// SILK/hybrid modes; at 128 kbps music the encoder uses CELT, where PLC does the work).
public final class OpusEncoder: AudioEncoder {
    public let codec: CodecID = .opus
    public let frameSamples: Int
    public let maxPayloadBytes = 1024
    private let enc: OpaquePointer

    public init(frameSamples: Int = Constants.opusFrameSamples, bitrate: Int = 128_000,
                lowDelay: Bool = true, fec: Bool = true, expectedLossPercent: Int = 5) throws {
        guard [120, 240, 480, 960, 1920, 2880].contains(frameSamples) else { throw OpusError.badFrameSize(frameSamples) }
        self.frameSamples = frameSamples
        var err: Int32 = 0
        let app = lowDelay ? OPUS_APPLICATION_RESTRICTED_LOWDELAY : OPUS_APPLICATION_AUDIO
        guard let e = opus_encoder_create(opus_int32(Constants.sampleRate), Int32(Constants.channels), app, &err), err == OPUS_OK else {
            throw OpusError.create(err)
        }
        enc = e
        _ = es_opus_encoder_set_bitrate(enc, Int32(bitrate))
        _ = es_opus_encoder_set_vbr(enc, 1)
        _ = es_opus_encoder_set_complexity(enc, 4)
        _ = es_opus_encoder_set_signal_music(enc)
        _ = es_opus_encoder_set_inband_fec(enc, fec ? 1 : 0)
        _ = es_opus_encoder_set_packet_loss_perc(enc, Int32(expectedLossPercent))
    }

    deinit { opus_encoder_destroy(enc) }

    /// Encoder lookahead in samples (algorithmic delay).
    public var lookaheadSamples: Int { Int(es_opus_encoder_lookahead(enc)) }

    public func encode(_ pcm: UnsafePointer<Float>, into out: UnsafeMutablePointer<UInt8>) -> Int {
        let n = opus_encode_float(enc, pcm, Int32(frameSamples), out, opus_int32(maxPayloadBytes))
        return n > 0 ? Int(n) : 0
    }
}

public final class OpusDecoder: AudioDecoder {
    public let codec: CodecID = .opus
    public let frameSamples: Int
    private let dec: OpaquePointer
    private let count: Int

    public init(frameSamples: Int = Constants.opusFrameSamples) throws {
        guard [120, 240, 480, 960, 1920, 2880].contains(frameSamples) else { throw OpusError.badFrameSize(frameSamples) }
        self.frameSamples = frameSamples
        count = frameSamples * Constants.channels
        var err: Int32 = 0
        guard let d = opus_decoder_create(opus_int32(Constants.sampleRate), Int32(Constants.channels), &err), err == OPUS_OK else {
            throw OpusError.create(err)
        }
        dec = d
    }

    deinit { opus_decoder_destroy(dec) }

    public func decode(_ payload: UnsafeRawBufferPointer, into pcm: UnsafeMutablePointer<Float>) -> Bool {
        guard let base = payload.baseAddress?.assumingMemoryBound(to: UInt8.self), payload.count > 0 else {
            conceal(into: pcm)
            return false
        }
        let n = opus_decode_float(dec, base, opus_int32(payload.count), pcm, Int32(frameSamples), 0)
        if n != Int32(frameSamples) {
            pcm.update(repeating: 0, count: count)
            return false
        }
        return true
    }

    public func conceal(into pcm: UnsafeMutablePointer<Float>) {
        let n = opus_decode_float(dec, nil, 0, pcm, Int32(frameSamples), 0)
        if n != Int32(frameSamples) { pcm.update(repeating: 0, count: count) }
    }

    public func decodeFEC(nextPayload: UnsafeRawBufferPointer, into pcm: UnsafeMutablePointer<Float>) -> Bool {
        guard let base = nextPayload.baseAddress?.assumingMemoryBound(to: UInt8.self), nextPayload.count > 0 else { return false }
        let n = opus_decode_float(dec, base, opus_int32(nextPayload.count), pcm, Int32(frameSamples), 1)
        return n == Int32(frameSamples)
    }

    public func reset() { _ = es_opus_decoder_reset(dec) }
}
