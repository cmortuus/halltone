import Foundation
import HalltoneDialog
import HalltoneDialogEval

let usage = """
usage: halltone-dialog-eval in.wav [--labels labels.txt] [--merge-gap SECONDS]
       halltone-dialog-eval --make-demo out.wav --labels-out labels.txt [--voices a,b,c] [--speech-gain G] [--music-gain G]
                           [--speech-over-music-db DB]   (scale lines by RMS instead of peak)
                                                                    (needs `say` or `espeak-ng`)
       halltone-dialog-eval --make-signal sine|pink|music out.wav          [--amp A] (30 s non-speech test signal)

Runs the dialog detector over a WAV (any rate; resampled to 48 kHz stereo) and prints the event
timeline. With Audacity-format labels (start<TAB>end<TAB>label, seconds) it also prints frame
precision/recall and the median start/end latency.

Threshold overrides: --side-scale X  --band-ratio X  --min-level DB  --vad-mode N
                     --start-ms N  --window-ms N  --end-ms N
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { fail("\(flag) needs a value\n\n\(usage)") }
    let v = args[i + 1]
    args.removeSubrange(i...i + 1)
    return v
}
func number(_ flag: String) -> Double? {
    guard let s = take(flag) else { return nil }
    guard let v = Double(s) else { fail("\(flag): not a number: \(s)") }
    return v
}

if args.contains("-h") || args.contains("--help") || args.isEmpty { print(usage); exit(args.isEmpty ? 2 : 0) }

// --make-demo: speech (TTS) over wide music-like noise, plus a labels file.
if let out = take("--make-demo") {
    guard let labelsOut = take("--labels-out") else { fail("--make-demo needs --labels-out\n\n\(usage)") }
    let lines = ["The door is locked. You will need to find the key.",
                 "Watch out, there are guards on the next floor.",
                 "I knew you would come back, it has been a very long time."]
    let voices: [String?] = (take("--voices") ?? "").split(separator: ",").map { String($0) }
    let speech = Float(number("--speech-gain") ?? 0.5), music = Float(number("--music-gain") ?? 0.15)
    guard let demo = makeDemoMix(lines: lines, gaps: [4, 5], speechGain: speech, musicGain: music, voices: voices,
                           speechOverMusicDB: number("--speech-over-music-db")) else { fail("no text-to-speech engine (say / espeak-ng) found") }
    do {
        try WAV.write16(path: out, sampleRate: 48_000, channels: 2, samples: demo.samples)
        try Labels.format(demo.labels).write(toFile: labelsOut, atomically: true, encoding: .utf8)
    } catch { fail("write failed: \(error)") }
    print("wrote \(out) (\(String(format: "%.1f", Double(demo.samples.count / 2) / 48_000)) s) and \(labelsOut)")
    exit(0)
}

if let kind = take("--make-signal") {
    let amp = Float(number("--amp") ?? 0)
    guard args.count == 1 else { fail(usage) }
    let x: [Float]
    switch kind {
    case "sine": x = SyntheticAudio.sine(seconds: 30, hz: 440, amplitude: amp > 0 ? amp : 0.3)
    case "pink": x = SyntheticAudio.pinkNoise(seconds: 30, amplitude: amp > 0 ? amp : 0.1)
    case "music": x = SyntheticAudio.wideMusic(seconds: 30, amplitude: amp > 0 ? amp : 0.15)
    default: fail("unknown signal \(kind) (sine, pink, music)")
    }
    do { try WAV.write16(path: args[0], sampleRate: 48_000, channels: 2, samples: x) } catch { fail("write failed: \(error)") }
    print("wrote \(args[0])")
    exit(0)
}

var config = DialogConfig()
if let v = number("--side-scale") { config.centerSideScale = v }
if let v = number("--band-ratio") { config.speechBandRatioMin = v }
if let v = number("--min-level") { config.minLevelDBFS = v }
if let v = number("--vad-mode") { config.vadMode = Int(v) }
if let v = number("--start-ms") { config.startSpeechMs = Int(v) }
if let v = number("--window-ms") { config.startWindowMs = Int(v) }
if let v = number("--end-ms") { config.endSilenceMs = Int(v) }
let labelsPath = take("--labels")
let mergeGap = number("--merge-gap")
guard args.count == 1, !args[0].hasPrefix("--") else { fail(usage) }

let audio: WAV.Audio
do { audio = try WAV.read(path: args[0]) } catch { fail("\(args[0]): \(error)") }
let samples = WAV.toStereo48k(audio)
let frames = samples.count / 2
let duration = Double(frames) / 48_000
print(String(format: "%@: %.2f s, %d Hz, %d ch", args[0], Double(audio.frames) / Double(audio.sampleRate), audio.sampleRate, audio.channels))

let detector = DialogDetector(config: config)
var events: [DialogEvent] = []
var maxBlockSeconds = 0.0
let chunk = 480   // 10 ms, like a realistic audio callback
let wall0 = DispatchTime.now().uptimeNanoseconds
samples.withUnsafeBufferPointer { buf in
    var pos = 0
    while pos < frames {
        let n = min(chunk, frames - pos)
        let t0 = DispatchTime.now().uptimeNanoseconds
        detector.process(buf.baseAddress! + 2 * pos, frames: n) { events.append($0) }
        maxBlockSeconds = max(maxBlockSeconds, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9)
        pos += n
    }
}
let wall = Double(DispatchTime.now().uptimeNanoseconds - wall0) / 1e9

print("\nEvents:")
if events.isEmpty { print("  (none)") }
for e in events {
    switch e {
    case .started(let t, let d): print(String(format: "  %8.2f s  START   (detected at %.2f s, +%.2f s)", t, d, d - t))
    case .ended(let t, let d): print(String(format: "  %8.2f s  END     (detected at %.2f s, +%.2f s)", t, d, d - t))
    }
}
print(String(format: "\nCPU: %.3f s for %.2f s of audio = %.2f%% of one core (worst 10 ms block: %.3f ms)",
             wall, duration, 100 * wall / duration, maxBlockSeconds * 1000))

if let lp = labelsPath {
    guard let text = try? String(contentsOfFile: lp, encoding: .utf8) else { fail("cannot read \(lp)") }
    var labels = Labels.parse(text)
    if let g = mergeGap { labels = mergeLabels(labels, gap: g) }
    let r = evaluate(events: events, labels: labels, streamEnd: duration)
    print("\nLabels: \(labels.count)")
    print(String(format: "Frame precision: %.1f%%   recall: %.1f%%   (10 ms frames, event interval vs. label)", 100 * r.precision, 100 * r.recall))
    func fmt(_ v: [Double], _ matched: Int) -> String {
        guard let m = EvalReport.median(v) else { return "n/a (0/\(r.labelCount) matched)" }
        return String(format: "%.2f s median (%d/%d matched)", m, matched, r.labelCount)
    }
    print("Start latency (detected − label start): " + fmt(r.startLatencies, r.matchedStarts))
    print("End latency   (detected − label end):   " + fmt(r.endLatencies, r.matchedEnds))
}
