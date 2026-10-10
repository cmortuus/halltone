import Testing
import Foundation
@testable import HalltoneCore

@Suite struct CodecTests {
    @Test func pcm16RoundTrip() {
        let enc = PCM16Encoder()
        let dec = PCM16Decoder()
        let n = enc.frameSamples * 2
        var pcm = (0..<n).map { Float(sin(Double($0) * 0.1)) * 0.8 }
        var out = [UInt8](repeating: 0, count: enc.maxPayloadBytes)
        let bytes = pcm.withUnsafeBufferPointer { p in out.withUnsafeMutableBufferPointer { o in enc.encode(p.baseAddress!, into: o.baseAddress!) } }
        #expect(bytes == 960)
        var back = [Float](repeating: 0, count: n)
        let ok = out.withUnsafeBytes { raw in back.withUnsafeMutableBufferPointer { b in dec.decode(raw, into: b.baseAddress!) } }
        #expect(ok)
        for i in 0..<n { #expect(abs(back[i] - pcm[i]) < 2.5 / 32768) }
        // Conceal fades to silence.
        dec.conceal(into: &back)
        #expect(abs(back[0]) <= abs(pcm[0]) + 1e-6)
        #expect(back[n - 1] == 0)
        // Bad payload length -> silence, false.
        pcm = [Float](repeating: 1, count: n)
        let bad = out.withUnsafeBytes { raw in pcm.withUnsafeMutableBufferPointer { b in dec.decode(UnsafeRawBufferPointer(rebasing: raw[0..<10]), into: b.baseAddress!) } }
        #expect(!bad)
        #expect(pcm.allSatisfy { $0 == 0 })
    }
}
