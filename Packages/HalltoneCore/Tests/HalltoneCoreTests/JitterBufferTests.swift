import Testing
import Foundation
@testable import HalltoneCore

/// Drives a JitterBuffer with a synthetic sender clock and a synthetic playout clock.
struct JitterSim {
    var config: JitterBuffer.Config
    var loss: Double = 0
    var jitterMs: Double = 0
    var reorder: Bool = false
    /// Receiver clock drift relative to sender, in parts per million (+ = receiver consumes faster).
    var driftPPM: Double = 0
    var seconds: Double = 10
    var seed: UInt64 = 1

    struct Result {
        var frames = 0, conceals = 0, waits = 0, drops = 0, dups = 0
        var stats = JitterBuffer.Stats()
        var maxGapFrames = 0
        var firstEmitTime: TimeInterval = 0
    }

    func run() -> Result {
        var rng = SplitMix(seed: seed)
        let jb = JitterBuffer(config: config)
        let frame = config.frameSamples
        let frameDur = Double(frame) / config.sampleRate
        // Build arrival schedule.
        var arrivals: [(t: TimeInterval, pos: UInt64)] = []
        let n = Int(seconds / frameDur)
        for i in 0..<n {
            if rng.nextDouble() < loss { continue }
            var t = Double(i) * frameDur + 0.02 + rng.nextDouble() * jitterMs / 1000
            if reorder, rng.nextDouble() < 0.1 { t += frameDur * 2 }
            arrivals.append((t, UInt64(i * frame)))
        }
        arrivals.sort { $0.t < $1.t }
        var ai = 0
        // Playout: the "render callback" consumes `frame` samples every frameDur / (1 + drift).
        // The decode pump runs every 1 ms and keeps the hand-off ring >= 1 frame.
        var ring = 0 // samples decoded but not rendered
        var r = Result()
        var t: TimeInterval = 0
        var nextRender = 0.0
        let renderPeriod = frameDur / (1 + driftPPM / 1e6)
        var curGap = 0
        var primedOnce = false
        // Stop rendering shortly before the sender does, so the tail isn't counted as underruns.
        while t < seconds - 0.2 {
            while ai < arrivals.count, arrivals[ai].t <= t {
                jb.push(session: 1, samplePos: arrivals[ai].pos, payload: Data(repeating: 1, count: 4), now: t)
                ai += 1
            }
            pump: while ring < frame {
                switch jb.pull(playoutAhead: ring, now: t) {
                case .wait:
                    break pump
                case .frame:
                    r.frames += 1; ring += frame
                    if !primedOnce { primedOnce = true; r.firstEmitTime = t }
                case .conceal:
                    r.conceals += 1; ring += frame
                case .dropped:
                    r.drops += 1; ring += frame
                case .duplicate:
                    r.dups += 1; ring += frame
                }
            }
            if t >= nextRender {
                if ring >= frame { ring -= frame; curGap = 0 }
                else {
                    r.waits += 1; curGap += 1; r.maxGapFrames = max(r.maxGapFrames, curGap)
                    if jb.stats.primed { jb.reportUnderrun(now: t) }
                }
                nextRender += renderPeriod
            }
            t += 0.001
        }
        r.stats = jb.stats
        return r
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextDouble() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

extension JitterSim.Result: CustomStringConvertible {
    var description: String {
        "frames \(frames) conceals \(conceals) waits \(waits) drops \(drops) dups \(dups) maxGap \(maxGapFrames) first \(firstEmitTime) | target \(stats.targetMs) depth \(Int(stats.depthMs)) lost \(stats.lost) late \(stats.late) under \(stats.underruns) resets \(stats.resets)"
    }
}

@Suite struct JitterBufferTests {
    var cfg: JitterBuffer.Config { JitterBuffer.Config(frameSamples: 480) }

    @Test func printScenarios() {
        var c = cfg
        print("clean:", JitterSim(config: cfg, seconds: 5).run())
        print("loss5:", JitterSim(config: cfg, loss: 0.05, seconds: 10, seed: 7).run())
        print("loss20:", JitterSim(config: cfg, loss: 0.20, seconds: 10, seed: 7).run())
        print("jitter40+reorder:", JitterSim(config: cfg, jitterMs: 40, reorder: true, seconds: 10, seed: 3).run())
        c.initialTargetMs = 30
        print("jitter80 from 30:", JitterSim(config: c, jitterMs: 80, seconds: 20, seed: 5).run())
        print("drift -200:", JitterSim(config: cfg, driftPPM: -200, seconds: 120).run())
        print("drift +400:", JitterSim(config: cfg, driftPPM: 400, seconds: 180).run())
        c.initialTargetMs = 100
        print("quiet from 100:", JitterSim(config: c, seconds: 40).run())
    }

    @Test func cleanStreamPlaysEveryFrameOnce() {
        let r = JitterSim(config: cfg, seconds: 5).run()
        #expect(r.conceals == 0)
        #expect(r.stats.underruns == 0)
        #expect(r.frames >= 470 && r.frames <= 500)
        #expect(abs(r.stats.depthMs - 60) < 15)
        #expect(r.waits <= 8) // only the pre-prime ticks
    }

    @Test func primesAtTargetDepth() {
        let r = JitterSim(config: cfg, seconds: 2).run()
        // First packet arrives at 20 ms; priming needs 60 ms of audio -> ~80 ms.
        #expect(r.firstEmitTime > 0.07 && r.firstEmitTime < 0.1)
    }

    @Test func lossIsConcealedNotStalled() {
        for loss in [0.05, 0.20] {
            let r = JitterSim(config: cfg, loss: loss, seconds: 10, seed: 7).run()
            let total = r.frames + r.conceals
            #expect(total >= 970, "loss \(loss): emitted \(total)")
            #expect(Double(r.conceals) / Double(total) > loss * 0.6 && Double(r.conceals) / Double(total) < loss * 1.4)
            #expect(r.stats.underruns == 0, "loss \(loss) underruns \(r.stats.underruns)")
        }
    }

    @Test func jitterAndReorderWithinTarget() {
        let r = JitterSim(config: cfg, jitterMs: 40, reorder: true, seconds: 10, seed: 3).run()
        #expect(r.conceals <= 2, "conceals \(r.conceals)")
        #expect(r.stats.underruns <= 1)
        #expect(r.stats.late <= 2)
    }

    @Test func heavyJitterRaisesTargetAndRecovers() {
        var c = cfg
        c.initialTargetMs = 30
        let r = JitterSim(config: c, jitterMs: 80, seconds: 20, seed: 5).run()
        #expect(r.stats.targetMs > 30)
        #expect(r.stats.targetMs <= 250)
        // Should settle: far fewer than one underrun per second.
        #expect(r.stats.underruns < 10, "underruns \(r.stats.underruns)")
    }

    @Test func driftIsCorrectedWithoutCreep() {
        // Sender 200 ppm fast (receiver slow): depth grows ~12 ms/min -> drops.
        let slow = JitterSim(config: cfg, driftPPM: -200, seconds: 120).run()
        #expect(slow.drops >= 1, "drops \(slow.drops)")
        #expect(abs(slow.stats.depthMs - slow.stats.targetMs) < 20, "\(slow)")
        #expect(slow.stats.underruns == 0, "\(slow)")
        // Receiver fast: depth shrinks -> duplicates. Target also decays to the 30 ms floor
        // while the link is clean, so the depth must track it there without underruns.
        let fast = JitterSim(config: cfg, driftPPM: 400, seconds: 180).run()
        #expect(fast.dups >= 1, "dups \(fast.dups)")
        #expect(abs(fast.stats.depthMs - fast.stats.targetMs) < 20, "\(fast)")
        #expect(fast.stats.underruns <= 1, "\(fast)")
    }

    @Test func targetLowersWhenQuiet() {
        var c = cfg
        c.initialTargetMs = 100
        let r = JitterSim(config: c, seconds: 40).run()
        #expect(r.stats.targetMs < 100)
        #expect(r.stats.underruns == 0)
    }

    @Test func sessionChangeAndJumpFlush() {
        let jb = JitterBuffer(config: cfg)
        for i in 0..<10 { jb.push(session: 1, samplePos: UInt64(i * 480), payload: Data(), now: Double(i) * 0.01) }
        #expect(jb.pull(playoutAhead: 0, now: 0.1) != .wait)
        jb.push(session: 2, samplePos: 0, payload: Data(), now: 0.2)
        #expect(jb.stats.resets == 1)
        #expect(jb.pull(playoutAhead: 0, now: 0.2) == .wait) // re-priming
        for i in 1..<8 { jb.push(session: 2, samplePos: UInt64(i * 480), payload: Data(), now: 0.2 + Double(i) * 0.01) }
        #expect(jb.pull(playoutAhead: 0, now: 0.3) == .frame(pos: 0, payload: Data()))
        // Jump > 1 s
        jb.push(session: 2, samplePos: 48000 * 5, payload: Data(), now: 0.4)
        #expect(jb.stats.resets == 2)
    }

    @Test func duplicatesAndLateDropped() {
        let jb = JitterBuffer(config: cfg)
        for i in 0..<8 { jb.push(session: 1, samplePos: UInt64(i * 480), payload: Data([UInt8(i)]), now: 0.1) }
        jb.push(session: 1, samplePos: 480, payload: Data([9]), now: 0.1)
        #expect(jb.stats.duplicates == 1)
        #expect(jb.pull(playoutAhead: 0, now: 0.2) == .frame(pos: 0, payload: Data([0])))
        #expect(jb.pull(playoutAhead: 0, now: 0.2) == .frame(pos: 480, payload: Data([1])))
        jb.push(session: 1, samplePos: 0, payload: Data(), now: 0.3)
        #expect(jb.stats.late == 1)
    }

    @Test func lossReportsNextForFEC() {
        let jb = JitterBuffer(config: cfg)
        for i in 0..<8 where i != 1 { jb.push(session: 1, samplePos: UInt64(i * 480), payload: Data([UInt8(i)]), now: 0.1) }
        #expect(jb.pull(playoutAhead: 0, now: 0.2) == .frame(pos: 0, payload: Data([0])))
        #expect(jb.pull(playoutAhead: 0, now: 0.2) == .conceal(pos: 480, next: Data([2])))
        #expect(jb.pull(playoutAhead: 0, now: 0.2) == .frame(pos: 960, payload: Data([2])))
    }
}
