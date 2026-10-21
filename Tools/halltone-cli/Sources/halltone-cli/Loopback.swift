import Foundation
import AVFoundation
import Network
import HalltoneCore
import HalltoneSender
import HalltoneReceiver

// MARK: - send

func runSend(port: UInt16, sourceKind: String, codec: CodecID, mute: Bool, pairingCode: UInt32?, advertise: Bool,
             seconds: Double?, simLoss: Double, simJitterMs: Double, latencyLog: URL?, swapEvery: Double? = nil, burstMs: Double = 0, burstEveryMs: Double = 2000) throws {
    var cfg = Sender.Config()
    cfg.port = port
    cfg.codec = codec
    cfg.pairingCode = pairingCode
    cfg.advertise = advertise
    cfg.simulatedLoss = simLoss
    cfg.simulatedJitterMs = simJitterMs
    cfg.simulatedBurstMs = burstMs
    cfg.simulatedBurstEveryMs = burstEveryMs
    let latencyWriter = try latencyLog.map { try CSVWriter(url: $0) }
    let sender = Sender(config: cfg) {
        if sourceKind == "tone" { return ToneSource() }
        return ProcessTapSource(muteWhileTapped: mute, excludedProcesses: [getpid()])
    }
    var lastLine = ""
    sender.onStats = { s in
        let subs = s.subscribers.map { "\($0.name) buf=\($0.bufferMs)ms loss=\($0.lossPermille)‰" }.joined(separator: ", ")
        var line = "[send] \(s.listening ? "listening" : "not listening") capture=\(s.capturing) \(s.packetsPerSecond) pkt/s \(s.kilobitsPerSecond) kbps subscribers: [\(subs)]"
        if let e = s.captureError { line += " CAPTURE ERROR: \(e)" }
        if line != lastLine { print(line); fflush(stdout); lastLine = line }
    }
    sender.onPacketSent = { pos, ns in latencyWriter?.write(pos, ns) }
    sender.onControl = { cmd in print("[send] control: \(cmd) (the CLI can't press media keys)"); return false }
    try sender.start()
    var swapTimer: Timer?
    if let swapEvery {
        swapTimer = Timer.scheduledTimer(withTimeInterval: swapEvery, repeats: true) { _ in
            print("[send] simulating output device change"); fflush(stdout)
            sender.simulateOutputDeviceChange()
        }
    }
    defer { swapTimer?.invalidate() }
    print("sending on udp/\(port) source=\(sourceKind) codec=\(codec) pairing=\(pairingCode.map(String.init) ?? "none") sim-loss=\(simLoss) sim-jitter=\(simJitterMs)ms")
    if let seconds {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    } else {
        signal(SIGINT) { _ in exit(0) }
        RunLoop.main.run()
    }
    sender.stop()
    latencyWriter?.close()
}

// MARK: - receive

func runReceive(target: String, pairingCode: UInt32, name: String, wav: URL?, seconds: Double?, latencyLog: URL?) throws {
    let latencyWriter = try latencyLog.map { try CSVWriter(url: $0) }
    let endpoint: NWEndpoint
    if let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]) {
        endpoint = .hostPort(host: NWEndpoint.Host(String(target[..<colon])), port: NWEndpoint.Port(rawValue: port)!)
    } else {
        endpoint = .hostPort(host: NWEndpoint.Host(target), port: NWEndpoint.Port(rawValue: Constants.defaultPort)!)
    }
    let sink: PlaybackSink = try wav.map { try WavSink(url: $0) } ?? PlaybackEngine()
    let receiver = Receiver(sink: sink)
    receiver.onState = { st in print("[recv] state: \(st)"); fflush(stdout) }
    receiver.onStats = { s in
        guard s.state.isActive else { return }
        print("[recv] cb \(s.callbackFrames) \(s.packetsPerSecond) pkt/s \(s.kilobitsPerSecond) kbps buffer \(s.bufferMs)/\(s.targetMs) ms loss \(s.lossPercent)% concealed \(s.concealed) underruns \(s.underruns) est. latency \(s.estimatedLatencyMs) ms resend asked \(s.resendRequested) recovered \(s.resendRecovered) late \(s.lateFrames)")
        fflush(stdout)
    }
    receiver.onFrameScheduled = { pos, ns in latencyWriter?.write(pos, ns) }
    var lastFlags: StatusFlags?
    receiver.onMacStatus = { flags in
        if flags != lastFlags {
            lastFlags = flags
            print("[recv] mac status: headphone controls \(flags.contains(.controlsAvailable) ? "ON" : "OFF")\(flags.contains(.lastControlFailed) ? ", last control failed" : "")")
            fflush(stdout)
        }
    }
    receiver.deviceID = ProcessInfo.processInfo.environment["HALLTONE_DEVICE_ID"]
    receiver.connect(to: endpoint, pairingCode: pairingCode, deviceName: name)
    // Test hook: pause (headphones out) partway through, then resume 8 s later.
    if let after = ProcessInfo.processInfo.environment["HALLTONE_PAUSE_AFTER"].flatMap(Double.init) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            print("[recv] pausing (test)"); fflush(stdout)
            receiver.listening = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                print("[recv] listening again (test)"); fflush(stdout)
                receiver.listening = true
            }
        }
    }
    // Test hook: disconnect and reconnect partway through (as the phone's Disconnect/Connect).
    if let after = ProcessInfo.processInfo.environment["HALLTONE_RECONNECT_AFTER"].flatMap(Double.init) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            print("[recv] disconnecting (test)"); fflush(stdout)
            receiver.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("[recv] reconnecting (test)"); fflush(stdout)
                receiver.connect(to: endpoint, pairingCode: pairingCode, deviceName: name)
            }
        }
    }
    if let seconds {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    } else {
        signal(SIGINT) { _ in exit(0) }
        RunLoop.main.run()
    }
    receiver.disconnect()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    if let w = sink as? WavSink { print("wrote \(w.framesWritten) frames, \(w.underruns.load()) underrun callbacks") }
    latencyWriter?.close()
}

final class CSVWriter {
    private let handle: FileHandle
    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }
    func write(_ pos: UInt64, _ ns: UInt64) { handle.write("\(pos),\(ns)\n".data(using: .utf8)!) }
    func close() { try? handle.close() }
}

/// Joins the sender's and receiver's latency logs (same machine, same uptime clock) by samplePos.
func reportLatency(send: URL, receive: URL) throws {
    func load(_ u: URL) throws -> [UInt64: UInt64] {
        var m: [UInt64: UInt64] = [:]
        for line in try String(contentsOf: u, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: ",")
            if parts.count == 2, let p = UInt64(parts[0]), let t = UInt64(parts[1]) { m[p] = t }
        }
        return m
    }
    let s = try load(send), r = try load(receive)
    var deltas: [Double] = []
    for (pos, ts) in s { if let tr = r[pos], tr >= ts { deltas.append(Double(tr - ts) / 1e6) } }
    guard !deltas.isEmpty else { print("no matching samples"); return }
    deltas.sort()
    let mean = deltas.reduce(0, +) / Double(deltas.count)
    let p50 = deltas[deltas.count / 2], p95 = deltas[Int(Double(deltas.count) * 0.95)], mx = deltas.last!
    print("latency over \(deltas.count) samples (encode → scheduled at sink): mean \(String(format: "%.1f", mean)) ms, p50 \(String(format: "%.1f", p50)), p95 \(String(format: "%.1f", p95)), max \(String(format: "%.1f", mx))")
    print("add capture IO buffer (~5-10 ms) and the output device latency on top.")
}

/// A PlaybackSink that writes to a WAV file, pulling from the ring at a steady 48 kHz like a render
/// callback would (with 5 ms callbacks). Silence is written on underrun, as the engine would.
final class WavSink: PlaybackSink {
    let ring = RingBuffer(capacity: 1 << 17)
    let underruns = AtomicCounter()
    let renderedFrames = AtomicUInt64()
    let wake = DispatchSemaphore(value: 0)
    let maxCallbackFrames = AtomicCounter()
    private(set) var framesWritten = 0
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private var thread: Thread?
    private var running = false

    init(url: URL) throws {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Constants.sampleRate, channels: 2, interleaved: true)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Constants.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
    }

    func start() throws {
        guard !running else { return }
        running = true
        let t = Thread { [self] in
            let callbackFrames = Int(ProcessInfo.processInfo.environment["HALLTONE_CALLBACK_FRAMES"] ?? "") ?? 240
            _ = maxCallbackFrames.exchange(UInt32(callbackFrames))
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(callbackFrames))!
            let start = Date()
            var produced = 0
            while running {
                let target = Int(Date().timeIntervalSince(start) * Constants.sampleRate)
                while produced + callbackFrames <= target, running {
                    let p = buf.floatChannelData!.pointee
                    let got = ring.read(into: p, count: callbackFrames * 2)
                    if got < callbackFrames * 2 {
                        (p + got).update(repeating: 0, count: callbackFrames * 2 - got)
                        underruns.add(1)
                    }
                    buf.frameLength = AVAudioFrameCount(callbackFrames)
                    try? file.write(from: buf)
                    produced += callbackFrames
                    framesWritten += callbackFrames
                    renderedFrames.add(UInt64(callbackFrames))
                    wake.signal()
                }
                usleep(2_000)
            }
        }
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() { running = false; thread = nil }
}
