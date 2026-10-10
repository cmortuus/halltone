import Foundation
import AVFoundation

func writeTone(seconds: Double, frequency: Double, output: URL) throws {
    let rate = 48_000.0
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true)!
    let frames = Int(seconds * rate)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
    buf.frameLength = AVAudioFrameCount(frames)
    let p = buf.floatChannelData!.pointee
    for i in 0..<frames {
        let v = Float(0.5 * sin(2 * .pi * frequency * Double(i) / rate))
        p[2 * i] = v
        p[2 * i + 1] = v
    }
    try file.write(from: buf)
    print("wrote \(output.path): \(seconds)s \(frequency) Hz")
}

/// Prints RMS, peak and the dominant frequency (coarse DFT over 20 Hz..8 kHz).
func analyze(_ url: URL) throws {
    let file = try AVAudioFile(forReading: url)
    let fmt = file.processingFormat
    let frames = AVAudioFrameCount(file.length)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    try file.read(into: buf)
    let n = Int(buf.frameLength)
    let ch = Int(fmt.channelCount)
    // Mono mix.
    var mono = [Float](repeating: 0, count: n)
    if fmt.isInterleaved {
        let p = buf.floatChannelData!.pointee
        for i in 0..<n { var s: Float = 0; for c in 0..<ch { s += p[i * ch + c] }; mono[i] = s / Float(ch) }
    } else {
        for c in 0..<ch { let p = buf.floatChannelData![c]; for i in 0..<n { mono[i] += p[i] / Float(ch) } }
    }
    var sum: Double = 0, peak: Float = 0
    for v in mono { sum += Double(v * v); peak = max(peak, abs(v)) }
    let rms = sqrt(sum / Double(max(n, 1)))
    // Dominant frequency: Goertzel over a 10 Hz grid on a 1 s window from the middle.
    let rate = fmt.sampleRate
    let win = min(n, Int(rate))
    let start = (n - win) / 2
    var bestF = 0.0, bestP = 0.0
    var f = 20.0
    while f <= 8000 {
        let w = 2 * .pi * f / rate
        let c = 2 * cos(w)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for i in start..<(start + win) {
            s0 = Double(mono[i]) + c * s1 - s2
            s2 = s1; s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - c * s1 * s2
        if power > bestP { bestP = power; bestF = f }
        f += (f < 1000 ? 5 : 20)
    }
    print("\(url.lastPathComponent): \(n) frames (\(String(format: "%.2f", Double(n) / rate)) s) @ \(rate) Hz, \(ch) ch")
    print("rms \(String(format: "%.4f", rms)), peak \(String(format: "%.4f", peak)), dominant ~\(Int(bestF)) Hz")
    // Count stretches of silence > 20 ms (dropouts).
    var silentRun = 0, dropouts = 0
    let thresh = Int(rate * 0.02)
    for v in mono {
        if abs(v) < 1e-4 { silentRun += 1 } else { if silentRun >= thresh { dropouts += 1 }; silentRun = 0 }
    }
    print("silent gaps >20ms (excluding tail): \(dropouts)")
}
