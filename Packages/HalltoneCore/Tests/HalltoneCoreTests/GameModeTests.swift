import Testing
import Foundation
@testable import HalltoneCore

/// `.game`: 2.5 ms frames (120 samples), 128-frame render callbacks, the pump keeping one
/// callback plus a frame decoded ahead.
@Suite struct GameModeTests {
    static let frame = 120
    static let frameDur = 120.0 / 48000
    static let callback = 128

    struct Run {
        var targetAfterWarmup = 0.0
        var maxTarget = 0.0
        var minTarget = 1000.0
        var conceals = 0
        var underruns = 0
        var drops = 0
        var dups = 0
        var finalTarget = 0.0
        var depthMs = 0.0
        var primedAt = 0.0
        var targetTrace: [(t: Double, target: Double)] = []
    }

    /// One sender, one jitter buffer, one render callback. `holds` are (start, length) windows
    /// during which no packet reaches the receiver; held packets arrive together at the end of
    /// the window (a Wi-Fi power-save clump). `jitterMs` delays each packet uniformly.
    static func run(config: JitterBuffer.Config = .preset(.game, frameSamples: frame), seconds: Double,
                    jitterMs: Double = 0, holds: [(start: Double, length: Double)] = [],
                    warmup: Double = 5, seed: UInt64 = 11) -> Run {
        var rng = SplitMix(seed: seed)
        let jb = JitterBuffer(config: config)
        var arrivals: [(t: Double, pos: UInt64)] = []
        for i in 0..<Int(seconds / frameDur) {
            var t = Double(i) * frameDur + 0.002 + rng.nextDouble() * jitterMs / 1000
            for h in holds where t >= h.start && t < h.start + h.length { t = h.start + h.length }
            arrivals.append((t, UInt64(i * frame)))
        }
        arrivals.sort { $0.t < $1.t }
        var ai = 0
        var r = Run()
        var ring = 0
        var t = 0.0, nextRender = 0.0
        var nextTrace = 0.0
        let lowWater = callback + frame
        while t < seconds - 0.1 {
            while ai < arrivals.count, arrivals[ai].t <= t {
                jb.push(session: 1, samplePos: arrivals[ai].pos, payload: Data([1]), now: t)
                ai += 1
            }
            pump: while ring < lowWater {
                switch jb.pull(playoutAhead: ring, now: t, concealBelow: callback) {
                case .wait: break pump
                case .conceal: ring += frame; if t > warmup { r.conceals += 1 }
                case .dropped: ring += frame; if t > warmup { r.drops += 1 }
                case .duplicate: ring += frame; if t > warmup { r.dups += 1 }
                case .frame: ring += frame
                }
            }
            if t >= nextRender {
                if ring >= callback { ring -= callback } else {
                    ring = 0
                    if jb.stats.primed { jb.reportUnderrun(now: t) }
                    if t > warmup { r.underruns += 1 }
                }
                nextRender += Double(callback) / 48000
            }
            if t > warmup {
                r.maxTarget = max(r.maxTarget, jb.stats.targetMs)
                r.minTarget = min(r.minTarget, jb.stats.targetMs)
            }
            if t >= nextTrace { r.targetTrace.append((t, jb.stats.targetMs)); nextTrace += 1 }
            if r.primedAt == 0, jb.stats.primed { r.primedAt = t }
            t += 0.0005
        }
        r.finalTarget = jb.stats.targetMs
        r.depthMs = jb.stats.depthMs
        return r
    }

    @Test func presetStartsAtFifteenMsWithinRange() {
        let c = JitterBuffer.Config.preset(.game, frameSamples: Self.frame)
        #expect(c.initialTargetMs == 15)
        #expect(c.minTargetMs >= 8 && c.minTargetMs <= 10)
        #expect(c.maxTargetMs == 60)
        #expect(c.minDecodedAheadMs == 0) // one callback plus a frame, not 20 ms
        #expect(JitterBuffer(config: c).stats.targetMs == 15)
        #expect(!LatencyMode.game.rawValue.isEmpty)
        #expect(LatencyMode.allCases.contains(.game))
        // Everything else keeps the 20 ms hand-off minimum.
        for m in [LatencyMode.lowest, .balanced, .stable, .auto] {
            #expect(JitterBuffer.Config.preset(m, frameSamples: 480).minDecodedAheadMs == 20)
        }
    }

    @Test func startsPlayingAtAboutFifteenMs() {
        let r = Self.run(seconds: 3)
        // First packet at 2 ms; priming needs a 15 ms target's worth.
        #expect(r.primedAt > 0.012 && r.primedAt < 0.03, "primed at \(r.primedAt)")
        #expect(r.conceals == 0 && r.underruns == 0)
    }

    @Test func cleanLinkSettlesAtTheFloorNeverBelow() {
        let r = Self.run(seconds: 60)
        print("game clean 60 s: target \(r.minTarget)–\(r.maxTarget), final \(r.finalTarget), depth \(r.depthMs), conceals \(r.conceals) under \(r.underruns) drops \(r.drops) dups \(r.dups)")
        let c = JitterBuffer.Config.preset(.game, frameSamples: Self.frame)
        #expect(r.minTarget >= c.minTargetMs)
        #expect(r.finalTarget <= 10, "decayed to \(r.finalTarget)") // fast decay: 15 → floor within a minute
        #expect(r.finalTarget >= c.minTargetMs)
        #expect(r.conceals == 0 && r.underruns == 0)
    }

    /// A 100 ms Wi-Fi power-save gap is longer than the 60 ms ceiling: no target could cover it,
    /// so it's concealed with a short fade and must not raise the target (Lowest's rule).
    @Test func singleLongGapDoesNotRatchetTheTarget() {
        let r = Self.run(seconds: 40, holds: [(20, 0.1)], warmup: 5)
        print("game single 100 ms gap: target \(r.minTarget)–\(r.maxTarget), final \(r.finalTarget), conceals \(r.conceals) under \(r.underruns) depth \(r.depthMs)")
        let clean = Self.run(seconds: 40, warmup: 5)
        #expect(r.maxTarget <= max(clean.maxTarget, 15), "target rose to \(r.maxTarget)")
        #expect(r.finalTarget <= clean.finalTarget + 5)
        #expect(r.conceals > 0 && r.conceals <= 48) // within maxConcealMs (120 ms / 2.5 ms)
        #expect(r.underruns == 0)
        // Latency didn't stick around after the gap: depth is back near the target.
        #expect(r.depthMs < r.finalTarget + 12, "depth \(r.depthMs) vs target \(r.finalTarget)")
    }

    @Test func repeatedLongGapsStillDontRatchet() {
        let holds = (0..<8).map { (start: 10.0 + Double($0) * 4, length: 0.1) }
        let r = Self.run(seconds: 60, holds: holds)
        print("game 8 gaps: target \(r.minTarget)–\(r.maxTarget), final \(r.finalTarget), conceals \(r.conceals) under \(r.underruns)")
        #expect(r.maxTarget <= 15)
        #expect(r.finalTarget <= 15)
    }

    /// A gap the ceiling can cover (40 ms) does raise the target, to gap + margin, and the
    /// target then decays again.
    @Test func coverableGapRaisesTargetThenDecays() {
        let r = Self.run(seconds: 60, holds: [(15, 0.04)])
        print("game 40 ms gap: target \(r.minTarget)–\(r.maxTarget), final \(r.finalTarget), conceals \(r.conceals)")
        #expect(r.maxTarget > 15 && r.maxTarget <= 60)
        #expect(r.finalTarget <= 12, "decayed to \(r.finalTarget)")
    }

    @Test func tenMsJitterStaysCleanAndLow() {
        let r = Self.run(seconds: 60, jitterMs: 10)
        print("game jitter 10: target \(r.minTarget)–\(r.maxTarget), final \(r.finalTarget), conceals \(r.conceals) under \(r.underruns) depth \(r.depthMs)")
        #expect(r.finalTarget <= 30)
        #expect(r.maxTarget <= 40)
        #expect(r.conceals <= 3)
    }

    @Test func neverExceedsCeilingEvenWithHeavyJitter() {
        let r = Self.run(seconds: 30, jitterMs: 200, seed: 3)
        #expect(r.maxTarget <= 60)
    }

    /// Frame size 120 flows through the codec and packet layers unchanged.
    @Test func pcm120FrameRoundTrips() {
        let n = Constants.pcmGameFrameSamples
        #expect(n == 120)
        let enc = PCM16Encoder(frameSamples: n), dec = PCM16Decoder(frameSamples: n)
        let pcm = (0..<(n * 2)).map { Float(sin(Double($0) * 0.05)) * 0.7 }
        var out = [UInt8](repeating: 0, count: enc.maxPayloadBytes)
        let bytes = pcm.withUnsafeBufferPointer { p in out.withUnsafeMutableBufferPointer { enc.encode(p.baseAddress!, into: $0.baseAddress!) } }
        #expect(bytes == 480)
        var back = [Float](repeating: 0, count: n * 2)
        let ok = out.withUnsafeBytes { raw in back.withUnsafeMutableBufferPointer { dec.decode(UnsafeRawBufferPointer(rebasing: raw[0..<bytes]), into: $0.baseAddress!) } }
        #expect(ok)
        for i in 0..<(n * 2) { #expect(abs(back[i] - pcm[i]) < 2.5 / 32768) }
        let p = Packet(seq: 1, session: 2, message: .subscribeAck(codec: .pcm16, sampleRate: 48000, channels: 2, frameSamples: UInt16(n), macName: "Mac"))
        #expect(Packet.decode(p.encode()) == p)
        let a = Packet(seq: 2, session: 2, message: .audio(samplePos: 4800, codec: .pcm16, payload: Data(out[0..<bytes])))
        #expect(Packet.decode(a.encode()) == a)
        #expect(a.encode().count <= Constants.maxDatagramBytes)
    }
}
