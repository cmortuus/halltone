import Foundation
import AVFoundation
import HalltoneCore
import HalltoneSender

/// M0: capture the system mix with the process tap for `seconds` and write a WAV.
func runCapture(seconds: Double, mute: Bool, tapOnly: Bool, autoStart: Bool, output: URL) throws {
    let ring = RingBuffer(capacity: 1 << 18) // ~2.7 s of stereo 48k
    let source = ProcessTapSource(muteWhileTapped: mute, excludedProcesses: [getpid()], tapOnly: tapOnly, autoStart: autoStart)
    let t0 = Date()
    try source.start(into: ring)
    print("tap start took \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    defer { source.stop() }
    guard let format = source.format else { throw NSError(domain: "halltone", code: 1, userInfo: [NSLocalizedDescriptionKey: "no format"]) }
    print("capturing \(seconds)s at \(format.sampleRate) Hz, \(format.channelCount) ch -> \(output.path)")
    print(source.diagnostics())

    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
    let chunkFrames: AVAudioFrameCount = 4800
    guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return }
    let ch = Int(format.channelCount)
    let deadline = Date().addingTimeInterval(seconds)
    var totalFrames = 0
    var peak: Float = 0
    var firstAudioAt: Double?
    let started = Date()
    while Date() < deadline {
        let want = Int(chunkFrames) * ch
        let got = pcm.floatChannelData!.pointee.withMemoryRebound(to: Float.self, capacity: want) {
            ring.read(into: $0, count: want)
        }
        if got == 0 { usleep(5_000); continue }
        let frames = got / ch
        pcm.frameLength = AVAudioFrameCount(frames)
        let p = pcm.floatChannelData!.pointee
        for i in 0..<got { peak = max(peak, abs(p[i])) }
        if firstAudioAt == nil, peak > 1e-3 { firstAudioAt = Date().timeIntervalSince(started) }
        try file.write(from: pcm)
        totalFrames += frames
    }
    print("first non-silent audio at \(firstAudioAt.map { String(format: "%.2f s", $0) } ?? "never")")
    print("wrote \(totalFrames) frames (\(String(format: "%.2f", Double(totalFrames) / format.sampleRate)) s), peak \(String(format: "%.3f", peak))")
    if peak < 1e-4 {
        print("WARNING: captured audio is silent. Either nothing was playing, or System Audio Recording permission is not granted.")
    }
}
