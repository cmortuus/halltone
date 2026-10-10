import Testing
import Foundation
@testable import HalltoneCore

@Suite struct OpusTests {
    @Test func roundTripIsCloseAndSmall() throws {
        let enc = try OpusEncoder()
        let dec = try OpusDecoder()
        let n = 480 * 2
        var payload = [UInt8](repeating: 0, count: enc.maxPayloadBytes)
        var out = [Float](repeating: 0, count: n)
        var sizes: [Int] = []
        var inputEnergy = 0.0, errorEnergy = 0.0
        let delay = enc.lookaheadSamples
        var history: [Float] = []
        var decodedAll: [Float] = []
        for f in 0..<100 {
            let pcm: [Float] = (0..<480).flatMap { i -> [Float] in
                let t = Double(f * 480 + i) / 48000
                let v = Float(0.4 * sin(2 * .pi * 440 * t) + 0.2 * sin(2 * .pi * 2500 * t))
                return [v, v * 0.8]
            }
            history += pcm
            let bytes = pcm.withUnsafeBufferPointer { p in payload.withUnsafeMutableBufferPointer { o in enc.encode(p.baseAddress!, into: o.baseAddress!) } }
            #expect(bytes > 0 && bytes <= 1000)
            sizes.append(bytes)
            let ok = payload.withUnsafeBytes { raw in out.withUnsafeMutableBufferPointer { o in dec.decode(UnsafeRawBufferPointer(rebasing: raw[0..<bytes]), into: o.baseAddress!) } }
            #expect(ok)
            decodedAll += out
        }
        // Compare decoded (delayed by lookahead) with input over the steady-state middle.
        for i in (20 * 960)..<(90 * 960) {
            let x = Double(history[i])
            let y = Double(decodedAll[i + delay * 2])
            inputEnergy += x * x
            errorEnergy += (x - y) * (x - y)
        }
        let snr = 10 * log10(inputEnergy / max(errorEnergy, 1e-12))
        let avg = sizes.dropFirst(5).reduce(0, +) / (sizes.count - 5)
        print("opus: lookahead \(delay) samples, avg packet \(avg) B (~\(avg * 8 * 100 / 1000) kbps), SNR \(snr) dB")
        #expect(snr > 15, "SNR \(snr)")
        #expect(avg > 100 && avg < 220)
        #expect(delay <= 480)
    }

    @Test func plcContinuesAndGarbageDoesNotCrash() throws {
        let enc = try OpusEncoder()
        let dec = try OpusDecoder()
        var payload = [UInt8](repeating: 0, count: enc.maxPayloadBytes)
        var out = [Float](repeating: 0, count: 960)
        for f in 0..<20 {
            let pcm: [Float] = (0..<480).flatMap { i -> [Float] in let v = Float(0.5 * sin(2 * .pi * 440 * Double(f * 480 + i) / 48000)); return [v, v] }
            let bytes = pcm.withUnsafeBufferPointer { p in payload.withUnsafeMutableBufferPointer { o in enc.encode(p.baseAddress!, into: o.baseAddress!) } }
            payload.withUnsafeBytes { raw in out.withUnsafeMutableBufferPointer { o in _ = dec.decode(UnsafeRawBufferPointer(rebasing: raw[0..<bytes]), into: o.baseAddress!) } }
        }
        // Concealment of a lost frame should not be silence (it extrapolates).
        out.withUnsafeMutableBufferPointer { dec.conceal(into: $0.baseAddress!) }
        let rms = sqrt(out.map { $0 * $0 }.reduce(0, +) / Float(out.count))
        #expect(rms > 0.05, "PLC rms \(rms)")
        // Garbage payloads must be rejected gracefully.
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let len = Int.random(in: 0...300, using: &rng)
            let junk = (0..<len).map { _ in UInt8.random(in: 0...255, using: &rng) }
            junk.withUnsafeBytes { raw in out.withUnsafeMutableBufferPointer { o in _ = dec.decode(raw, into: o.baseAddress!) } }
            junk.withUnsafeBytes { raw in out.withUnsafeMutableBufferPointer { o in _ = dec.decodeFEC(nextPayload: raw, into: o.baseAddress!) } }
        }
    }
}
