import Foundation
import HalltoneDialog

public struct Label: Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String = "") { self.start = start; self.end = end; self.text = text }
}

public enum Labels {
    /// Audacity label track: `start<TAB>end<TAB>text`, seconds. Blank lines, `#` comments and
    /// Audacity's `\`-prefixed frequency lines are ignored.
    public static func parse(_ text: String) -> [Label] {
        var out: [Label] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") || line.hasPrefix("\\") { continue }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 2, let s = Double(f[0].trimmingCharacters(in: .whitespaces)),
                  let e = Double(f[1].trimmingCharacters(in: .whitespaces)), e >= s else { continue }
            out.append(Label(start: s, end: e, text: f.count > 2 ? String(f[2]) : ""))
        }
        return out.sorted { $0.start < $1.start }
    }

    public static func format(_ labels: [Label]) -> String {
        labels.map { String(format: "%.6f\t%.6f\t%@", $0.start, $0.end, $0.text) }.joined(separator: "\n") + "\n"
    }
}

/// Dialog intervals `[start, end]` reconstructed from an event stream. A dialog still open at
/// `streamEnd` is closed there.
public func dialogIntervals(from events: [DialogEvent], streamEnd: Double) -> [(start: Double, end: Double)] {
    var out: [(Double, Double)] = []
    var open: Double?
    for e in events {
        switch e {
        case .started(let t, _): open = t
        case .ended(let t, _):
            if let s = open { out.append((s, max(s, t))); open = nil }
        }
    }
    if let s = open { out.append((s, streamEnd)) }
    return out
}

public struct EvalReport {
    public var precision: Double
    public var recall: Double
    /// Detection delay: `detectedAt − label.start` for each label that has a matching start event.
    public var startLatencies: [Double]
    /// `detectedAt − label.end` for each label end with a matching end event.
    public var endLatencies: [Double]
    public var matchedStarts = 0
    public var matchedEnds = 0
    public var labelCount = 0

    public static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
    }
}

/// Frame-level (10 ms) precision/recall of "dialog active" vs. labels, plus start/end latency.
///
/// Latency pairs each label with the first start event at or after (label.start − `slack`) and
/// before the label's end, and each label end with the first end event whose interval contains
/// or follows it (within `slack` seconds before and 5 s after). Because the detector bridges
/// short pauses, labels closer together than the hysteresis hold-off should be merged first
/// (see ``mergeLabels(_:gap:)``).
public func evaluate(events: [DialogEvent], labels: [Label], streamEnd: Double, slack: Double = 0.5) -> EvalReport {
    let dt = 0.01
    let frames = Int((streamEnd / dt).rounded(.up))
    var truth = [Bool](repeating: false, count: frames)
    var pred = truth
    for l in labels {
        let a = max(0, Int((l.start / dt).rounded())), b = min(frames, Int((l.end / dt).rounded()))
        if a < b { for i in a..<b { truth[i] = true } }
    }
    let intervals = dialogIntervals(from: events, streamEnd: streamEnd)
    for iv in intervals {
        let a = max(0, Int((iv.start / dt).rounded())), b = min(frames, Int((iv.end / dt).rounded()))
        if a < b { for i in a..<b { pred[i] = true } }
    }
    var tp = 0, fp = 0, fn = 0
    for i in 0..<frames {
        if truth[i] && pred[i] { tp += 1 } else if pred[i] { fp += 1 } else if truth[i] { fn += 1 }
    }
    var rep = EvalReport(precision: tp + fp > 0 ? Double(tp) / Double(tp + fp) : 1,
                         recall: tp + fn > 0 ? Double(tp) / Double(tp + fn) : 1,
                         startLatencies: [], endLatencies: [])
    rep.labelCount = labels.count
    let starts = events.filter { $0.isStart }
    let ends = events.filter { !$0.isStart }
    for l in labels {
        if let s = starts.first(where: { $0.time >= l.start - slack && $0.time <= l.end }) {
            rep.startLatencies.append(s.detectedAt - l.start); rep.matchedStarts += 1
        }
        if let e = ends.first(where: { $0.time >= l.end - slack && $0.time <= l.end + 5 }) {
            rep.endLatencies.append(e.detectedAt - l.end); rep.matchedEnds += 1
        }
    }
    return rep
}

/// Merges labels separated by less than `gap` seconds.
public func mergeLabels(_ labels: [Label], gap: Double) -> [Label] {
    var out: [Label] = []
    for l in labels.sorted(by: { $0.start < $1.start }) {
        if var last = out.last, l.start - last.end < gap {
            last.end = max(last.end, l.end)
            out[out.count - 1] = last
        } else { out.append(l) }
    }
    return out
}
