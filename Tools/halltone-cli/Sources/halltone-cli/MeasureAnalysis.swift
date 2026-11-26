import Foundation
import Accelerate

// Signal generation, click detection and the `measure --loopback` self-test for `halltone-cli measure`.
// Everything here is pure computation on sample arrays (no audio hardware), so the self-test can
// check the detector without a Mac mic or a phone.

/// The test "click": a short Hann-windowed linear chirp. A chirp correlates sharply (the matched
/// filter gives a peak a fraction of a millisecond wide even when the click is quiet, band-limited
/// by a phone speaker or smeared by Opus) while still sounding like a tick.
enum ClickSignal {
    static let startHz = 1500.0
    static let endHz = 10000.0
    static let seconds = 0.008

    /// The chirp at `rate`, unit peak amplitude.
    static func template(rate: Double) -> [Float] {
        let n = max(Int((seconds * rate).rounded()), 8)
        let sweep = (endHz - startHz) / seconds
        return (0..<n).map { i in
            let t = Double(i) / rate
            let window = 0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(n - 1)))
            return Float(window * sin(2 * Double.pi * (startHz * t + 0.5 * sweep * t * t)))
        }
    }
}

/// How many clicks, how far apart, and how long to wait before the first one.
struct ClickPlan {
    var clicks = 20
    var interval = 0.5      // seconds between clicks
    var leadIn = 1.5        // silence before the first click: the tap starts, the phone's buffer fills
    var level: Float = 0.5  // peak amplitude of each click (0...1)

    /// Sample position of each click in a train rendered at `rate`.
    func positions(rate: Double) -> [Int] {
        (0..<clicks).map { Int(((leadIn + Double(clicks > 0 ? $0 : 0) * interval) * rate).rounded()) }
    }
    /// Seconds from the start of the train to each click.
    func times(rate: Double) -> [Double] { positions(rate: rate).map { Double($0) / rate } }

    func render(rate: Double) -> [Float] {
        let tmpl = ClickSignal.template(rate: rate)
        let pos = positions(rate: rate)
        var out = [Float](repeating: 0, count: (pos.last ?? 0) + tmpl.count + Int(0.05 * rate))
        for p in pos { for (k, v) in tmpl.enumerated() { out[p + k] += v * level } }
        return out
    }
}

/// One detected click-shaped event in the recording.
struct Arrival {
    var time: Double   // seconds, same clock as the scheduled click times
    var score: Float   // normalized correlation, 0...1
}

struct ClickResult {
    var index: Int
    var scheduled: Double
    var arrivals: [Arrival]   // everything above threshold in this click's slot, in time order
    var direct: Arrival?      // the Mac's own speaker (or an echo of it), when it isn't muted
    var phone: Arrival?       // the path through Halltone and the phone

    /// Scheduled → heard through the phone, ms.
    var delayMs: Double? { phone.map { ($0.time - scheduled) * 1000 } }
    var directMs: Double? { direct.map { ($0.time - scheduled) * 1000 } }
}

struct MeasureReport {
    var clicks: [ClickResult]
    /// Median delay of the Mac's direct arrival over the clicks it showed up in; nil when the Mac was muted.
    var directMedianMs: Double?
    var directSlots: Int

    var delays: [Double] { clicks.compactMap { $0.delayMs } }
    var detected: Int { delays.count }
}

enum Detector {
    /// Arrivals this close after the first one in a slot are echoes of it, not a second path.
    static let echoWindow = 0.015

    /// Normalized cross-correlation of `samples` with the chirp: `result[n]` is how well the chirp
    /// starting at sample n matches, scaled to -1...1 by the signal's energy in that window, so a
    /// quiet click far from a loud one scores the same as a loud one.
    static func matchedFilter(_ samples: [Float], template: [Float]) -> [Float] {
        let n = samples.count, m = template.count
        guard n > 0, m > 0 else { return [] }
        let padded = samples + [Float](repeating: 0, count: m - 1)
        var corr = [Float](repeating: 0, count: n)
        vDSP_conv(padded, 1, template, 1, &corr, 1, vDSP_Length(n), vDSP_Length(m))
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(samples[i]) * Double(samples[i]) }
        let tnorm = sqrt(template.reduce(0.0) { $0 + Double($1) * Double($1) })
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let e = prefix[min(i + m, n)] - prefix[i]
            if e > 1e-10 { out[i] = Float(Double(corr[i]) / (tnorm * e.squareRoot())) }
        }
        return out
    }

    /// Strongest peaks of |ncc| in `range` above `threshold`, best first, each at least `minSep`
    /// samples from a stronger one, refined to a fraction of a sample by a parabola through the peak.
    static func peaks(_ ncc: [Float], in range: Range<Int>, threshold: Float, minSep: Int, limit: Int = 6) -> [(index: Double, score: Float)] {
        let lo = max(range.lowerBound, 0), hi = min(range.upperBound, ncc.count)
        guard lo + 2 < hi else { return [] }
        var mag = (lo..<hi).map { abs(ncc[$0]) }
        var found: [(Double, Float)] = []
        while found.count < limit {
            var peak: Float = 0, at = 0
            for (i, v) in mag.enumerated() where v > peak { peak = v; at = i }
            if peak < threshold { break }
            var frac = 0.0
            if at > 0, at + 1 < mag.count {
                let a = Double(mag[at - 1]), b = Double(mag[at]), c = Double(mag[at + 1])
                let denom = a - 2 * b + c
                if denom < 0 { frac = max(-0.5, min(0.5, 0.5 * (a - c) / denom)) }
            }
            found.append((Double(lo + at) + frac, peak))
            for i in max(0, at - minSep)...min(mag.count - 1, at + minSep) { mag[i] = 0 }
        }
        return found.map { (index: $0.0, score: $0.1) }
    }

    /// Finds each scheduled click in the recording.
    /// - samples: mono recording; sample n was heard at `recordStart + n / rate` seconds.
    /// - clickTimes: when each click was scheduled, same clock as `recordStart`.
    /// - slotLength: how long after a click to look for it (the click spacing).
    static func analyze(samples: [Float], rate: Double, recordStart: Double, clickTimes: [Double],
                        slotLength: Double, threshold: Float = 0.3, preroll: Double = 0.02) -> MeasureReport {
        let ncc = matchedFilter(samples, template: ClickSignal.template(rate: rate))
        let minSep = max(Int(0.002 * rate), 1)
        var clicks: [ClickResult] = []
        for (i, t) in clickTimes.enumerated() {
            let lo = Int(((t - preroll) - recordStart) * rate)
            let hi = Int(((t + slotLength - preroll) - recordStart) * rate)
            let arrivals = peaks(ncc, in: lo..<hi, threshold: threshold, minSep: minSep)
                .map { Arrival(time: recordStart + $0.index / rate, score: $0.score) }
                .sorted { $0.time < $1.time }
            clicks.append(ClickResult(index: i, scheduled: t, arrivals: arrivals))
        }

        // The Mac's own speaker: when mute-while-streaming is off the click reaches the mic directly
        // and again, much later, through the phone. A slot with a first arrival and another more
        // than `echoWindow` after it is such a pair; the first is the direct sound. It counts as the
        // Mac being unmuted if that happens in at least half of the slots that heard anything.
        var directDelays: [Double] = []
        for c in clicks {
            if let first = c.arrivals.first, c.arrivals.contains(where: { $0.time - first.time > echoWindow }) {
                directDelays.append(first.time - c.scheduled)
            }
        }
        let heard = clicks.filter { !$0.arrivals.isEmpty }.count
        let directMedian: Double? = (directDelays.count >= 2 && directDelays.count * 2 >= heard) ? median(directDelays) : nil
        if let d = directMedian {
            for k in clicks.indices {
                let t0 = clicks[k].scheduled
                // Drop the direct arrival and its echoes; the next arrival is the phone path.
                let rest = clicks[k].arrivals.filter { ($0.time - t0) > d + echoWindow || ($0.time - t0) < d - 0.003 }
                clicks[k].direct = clicks[k].arrivals.first { abs(($0.time - t0) - d) <= 0.003 }
                clicks[k].phone = rest.first { ($0.time - t0) > d + echoWindow }
            }
        } else {
            for k in clicks.indices { clicks[k].phone = clicks[k].arrivals.first }
        }
        return MeasureReport(clicks: clicks, directMedianMs: directMedian.map { $0 * 1000 }, directSlots: directMedian == nil ? 0 : directDelays.count)
    }
}

// MARK: - Statistics

func median(_ values: [Double]) -> Double {
    let s = values.sorted()
    guard !s.isEmpty else { return .nan }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// Nearest-rank percentile (p in 0...100): the smallest value with at least p% of the samples at or below it.
func percentile(_ values: [Double], _ p: Double) -> Double {
    let s = values.sorted()
    guard !s.isEmpty else { return .nan }
    let rank = Int((p / 100 * Double(s.count)).rounded(.up))
    return s[max(0, min(s.count - 1, rank - 1))]
}

func printReport(_ r: MeasureReport, total: Int, perClick: Bool = true) {
    let d = r.delays
    func ms(_ v: Double) -> String { String(format: "%7.1f ms", v) }
    print("")
    print("Delay from the click being scheduled on the Mac to it being heard from the phone:")
    print("  detected  \(r.detected) of \(total) clicks")
    if d.isEmpty {
        print("  (nothing heard from the phone)")
    } else {
        print("  min      \(ms(d.min()!))")
        print("  median   \(ms(median(d)))")
        print("  p95      \(ms(percentile(d, 95)))")
        print("  max      \(ms(d.max()!))")
    }
    if let direct = r.directMedianMs {
        print("Mac's own speakers were audible (mute-while-streaming off): direct sound at \(String(format: "%.1f", direct)) ms in \(r.directSlots) clicks, ignored above.")
        let rel = r.clicks.compactMap { c -> Double? in
            guard let p = c.phone else { return nil }
            return (p.time - c.scheduled) * 1000 - (c.directMs ?? direct)
        }
        if !rel.isEmpty {
            print("Phone behind the Mac's speakers by: min \(String(format: "%.1f", rel.min()!)), median \(String(format: "%.1f", median(rel))), p95 \(String(format: "%.1f", percentile(rel, 95))) ms")
        }
    }
    if perClick {
        let cells = r.clicks.map { c in c.delayMs.map { String(format: "%.1f", $0) } ?? "-" }
        print("Per click (ms): " + cells.joined(separator: " "))
    }
}

// MARK: - Self-test (measure --loopback)

/// Plays a click train through a synthetic delay line (no hardware), "records" it and checks the
/// detector recovers the known delay of every click to within ±1 ms. Returns true if all scenarios pass.
func runMeasureLoopback(wav: URL?) -> Bool {
    struct Scenario {
        var name: String
        var rate: Double
        var phoneDelayMs: Double
        var phoneGain: Float
        var jitterMs: Double = 0              // each click's delay varies by ±jitterMs
        var directDelayMs: Double? = nil      // Mac speakers audible: arrives this long after the click
        var directGain: Float = 1
        var noise: Float = 0.01               // RMS of white noise added
        var dropClicks: Set<Int> = []         // clicks the phone path never delivers
        var expectPhone: Bool = true
    }
    let scenarios = [
        Scenario(name: "48 kHz, 87.3 ms, quiet room", rate: 48_000, phoneDelayMs: 87.3, phoneGain: 0.4),
        Scenario(name: "44.1 kHz, 212.75 ms, ±3 ms jitter", rate: 44_100, phoneDelayMs: 212.75, phoneGain: 0.3, jitterMs: 3),
        Scenario(name: "Mac speakers audible (direct 9.5 ms, louder than phone)", rate: 48_000, phoneDelayMs: 143.2, phoneGain: 0.15,
                 directDelayMs: 9.5, directGain: 1, noise: 0.02),
        Scenario(name: "3 clicks never reach the phone", rate: 48_000, phoneDelayMs: 61.9, phoneGain: 0.5, dropClicks: [3, 4, 11]),
        Scenario(name: "direct only, 3 clicks missing, jitter", rate: 48_000, phoneDelayMs: 301.0, phoneGain: 0.25, jitterMs: 2,
                 directDelayMs: 4.0, directGain: 0.6, noise: 0.03, dropClicks: [0, 7, 19]),
        Scenario(name: "silence + noise only: no false detections", rate: 48_000, phoneDelayMs: 100, phoneGain: 0, noise: 0.05, expectPhone: false),
    ]
    var rng = SplitMix64(seed: 0x4841_4C4C)
    var allPass = true
    var worst = 0.0
    print("measure --loopback: synthetic delay line, no audio hardware")
    for (si, s) in scenarios.enumerated() {
        let plan = ClickPlan(clicks: 20, interval: 0.5, leadIn: 1.0, level: 0.5)
        let train = plan.render(rate: s.rate)
        let clickRel = plan.times(rate: s.rate)
        // Recording started 173 ms before playback did, on an arbitrary clock.
        let playStart = 98_765.4321, recordLead = 0.173
        let recordStart = playStart - recordLead
        let length = Int((recordLead + 1.0 + 20 * 0.5 + 1.5) * s.rate)
        var rec = [Float](repeating: 0, count: length)
        var truth: [Double?] = []
        for (i, rel) in clickRel.enumerated() {
            guard s.expectPhone, !s.dropClicks.contains(i) else { truth.append(nil); continue }
            let jitter = s.jitterMs == 0 ? 0 : (rng.nextUnit() * 2 - 1) * s.jitterMs
            let delay = s.phoneDelayMs + jitter
            // Delay line: this click's slice of the train, delayed by a fractional number of samples.
            let from = Int((rel * s.rate).rounded()), tmplLen = ClickSignal.template(rate: s.rate).count
            for k in 0..<(tmplLen + 4) where from + k < train.count {
                addFractional(&rec, value: train[from + k] * s.phoneGain, at: (recordLead + delay / 1000) * s.rate + Double(from + k))
            }
            truth.append(delay)
        }
        if let dd = s.directDelayMs {
            for rel in clickRel {
                let from = Int((rel * s.rate).rounded()), tmplLen = ClickSignal.template(rate: s.rate).count
                for k in 0..<(tmplLen + 4) where from + k < train.count {
                    addFractional(&rec, value: train[from + k] * s.directGain, at: (recordLead + dd / 1000) * s.rate + Double(from + k))
                    // A room reflection of the direct sound, 2.5 ms later and weaker.
                    addFractional(&rec, value: train[from + k] * s.directGain * 0.3, at: (recordLead + (dd + 2.5) / 1000) * s.rate + Double(from + k))
                }
            }
        }
        if s.noise > 0 { for i in rec.indices { rec[i] += s.noise * rng.nextGaussian() } }
        if si == 2, let wav { try? writeMonoWav(rec, rate: s.rate, to: wav) }

        let report = Detector.analyze(samples: rec, rate: s.rate, recordStart: recordStart,
                                      clickTimes: clickRel.map { playStart + $0 }, slotLength: plan.interval)
        var maxErr = 0.0, missed = 0, spurious = 0
        for (c, t) in zip(report.clicks, truth) {
            switch (c.delayMs, t) {
            case let (got?, want?): maxErr = max(maxErr, abs(got - want))
            case (nil, _?): missed += 1
            case (_?, nil): spurious += 1
            default: break
            }
        }
        var ok = maxErr <= 1.0 && missed == 0 && spurious == 0
        if let dd = s.directDelayMs {
            ok = ok && report.directMedianMs.map { abs($0 - dd) <= 1.0 } ?? false
        } else {
            ok = ok && report.directMedianMs == nil
        }
        worst = max(worst, maxErr)
        allPass = allPass && ok
        let detail = s.expectPhone
            ? String(format: "%d/%d detected, max error %.3f ms%@", report.detected, truth.compactMap { $0 }.count, maxErr,
                     report.directMedianMs.map { String(format: ", direct %.2f ms ignored", $0) } ?? "")
            : "\(report.detected) detections"
        print("  \(ok ? "PASS" : "FAIL")  \(s.name): \(detail)")
        if !ok && missed + spurious > 0 { print("        missed \(missed), spurious \(spurious)") }
    }
    print(allPass ? String(format: "measure --loopback: PASS (worst error %.3f ms, limit 1 ms)", worst) : "measure --loopback: FAIL")
    return allPass
}

/// Adds `value` into `buf` at a fractional sample position (linear interpolation between the two samples).
private func addFractional(_ buf: inout [Float], value: Float, at position: Double) {
    let i = Int(position.rounded(.down)), f = Float(position - Double(i))
    if i >= 0, i < buf.count { buf[i] += value * (1 - f) }
    if i + 1 >= 0, i + 1 < buf.count { buf[i + 1] += value * f }
}

/// Small deterministic generator so the self-test is reproducible.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func nextGaussian() -> Float {
        let u1 = max(nextUnit(), 1e-12), u2 = nextUnit()
        return Float((-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2))
    }
}
