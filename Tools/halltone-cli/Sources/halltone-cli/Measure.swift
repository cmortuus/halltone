import Foundation
import AVFoundation
import CoreAudio

// `halltone-cli measure`: plays a click train through the Mac's default output while recording a Mac
// input device, then finds each click in the recording. With the Halltone Mac app streaming to the
// phone and the phone's speaker/earbud held against the mic, the delay between "click scheduled" and
// "click heard from the phone" is the real end-to-end latency.

struct MeasureOptions {
    var plan = ClickPlan()
    var inputName: String?
    var wav: URL?
    var threshold: Float = 0.3
    var inputOffsetMs = 0.0
}

// MARK: - CoreAudio input devices

struct InputDevice {
    var id: AudioDeviceID
    var name: String
    var transport: UInt32
    var channels: Int
    var rate: Double
    /// Frames between the sound reaching the microphone and the sample appearing on the device's timeline.
    var latencyFrames: UInt32
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
}

private func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, zero: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = zero
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

private func inputChannelCount(_ id: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                             mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func listInputDevices() -> [InputDevice] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        let channels = inputChannelCount(id)
        guard channels > 0 else { return nil }
        let name = (property(id, kAudioObjectPropertyName, zero: nil as CFString?) ?? nil) as String? ?? "device \(id)"
        let deviceLatency = property(id, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeInput, zero: UInt32(0)) ?? 0
        var streamLatency: UInt32 = 0
        var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                        mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var streamsSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize >= 4 {
            var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(id, &streamsAddress, 0, nil, &streamsSize, &streams) == noErr, let first = streams.first {
                streamLatency = property(first, kAudioStreamPropertyLatency, zero: UInt32(0)) ?? 0
            }
        }
        return InputDevice(id: id, name: name,
                           transport: property(id, kAudioDevicePropertyTransportType, zero: UInt32(0)) ?? 0,
                           channels: channels,
                           rate: property(id, kAudioDevicePropertyNominalSampleRate, zero: Float64(0)) ?? 48_000,
                           latencyFrames: deviceLatency + streamLatency)
    }
}

/// `name` is a case-insensitive substring (an exact name wins). Without it: the built-in microphone,
/// else the system's default input.
func resolveInput(_ name: String?) throws -> InputDevice {
    let devices = listInputDevices()
    if let name {
        let q = name.lowercased()
        if let exact = devices.first(where: { $0.name.lowercased() == q }) { return exact }
        if let part = devices.first(where: { $0.name.lowercased().contains(q) }) { return part }
        throw MeasureError("no input device matching \"\(name)\". Available: " + devices.map { "\"\($0.name)\"" }.joined(separator: ", "))
    }
    if let builtIn = devices.first(where: { $0.isBuiltIn }) { return builtIn }
    if let id = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, zero: AudioDeviceID(0)),
       let d = devices.first(where: { $0.id == id }) { return d }
    if let first = devices.first { return first }
    throw MeasureError("no input devices found")
}

struct MeasureError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

// MARK: - Recording

/// Records one input device with a HAL IOProc, placing every buffer by its sample time so a
/// dropped callback leaves a gap of silence instead of shifting everything after it.
final class InputRecorder {
    let device: InputDevice
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var procID: AudioDeviceIOProcID?
    private var firstSampleTime = Double.nan
    private(set) var firstHostTime: UInt64 = 0
    private var expected = 0
    private(set) var gaps = 0
    private(set) var callbacks = 0

    init(device: InputDevice, seconds: Double) {
        self.device = device
        capacity = Int(seconds * device.rate)
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }
    deinit { buffer.deallocate() }

    func start() throws {
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) { [self] _, inData, inTime, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let first = list.first, first.mDataByteSize > 0 else { return }
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
            if firstSampleTime.isNaN {
                firstSampleTime = inTime.pointee.mSampleTime
                firstHostTime = inTime.pointee.mHostTime
            }
            let index = Int(inTime.pointee.mSampleTime - firstSampleTime)
            if index != expected { gaps += 1 }
            expected = index + frames
            callbacks += 1
            guard index >= 0, index + frames <= capacity else { return }
            let totalChannels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
            let scale = 1 / Float(max(totalChannels, 1))
            for f in 0..<frames {
                var sum: Float = 0
                for b in list {
                    guard let data = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let ch = Int(b.mNumberChannels)
                    for c in 0..<ch { sum += data[f * ch + c] }
                }
                buffer[index + f] = sum * scale
            }
        }
        guard status == noErr else { throw MeasureError("could not open \"\(device.name)\" (CoreAudio error \(status))") }
        let started = AudioDeviceStart(device.id, procID)
        guard started == noErr else { throw MeasureError("could not start \"\(device.name)\" (CoreAudio error \(started))") }
    }

    /// Stops and returns the recording (everything from the first callback to `seconds`).
    func stop() -> [Float] {
        if let procID {
            AudioDeviceStop(device.id, procID)
            AudioDeviceDestroyIOProcID(device.id, procID)
            self.procID = nil
        }
        return Array(UnsafeBufferPointer(start: buffer, count: capacity))
    }
}

func writeMonoWav(_ samples: [Float], rate: Double, to url: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buf)
}

// MARK: - measure

func runMeasure(_ o: MeasureOptions) throws {
    let plan = o.plan
    guard plan.clicks >= 1, plan.interval >= 0.1, plan.level > 0, plan.level <= 1 else {
        throw MeasureError("need --clicks >= 1, --interval >= 100 (ms) and --level in 0...1")
    }
    // Microphone permission: without it CoreAudio delivers silence rather than an error.
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: break
    case .notDetermined:
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { granted = $0; sem.signal() }
        sem.wait()
        guard granted else { throw MeasureError("microphone access denied") }
    default:
        throw MeasureError("microphone access is off for this terminal: System Settings → Privacy & Security → Microphone")
    }

    let input = try resolveInput(o.inputName)
    let inputLatency = Double(input.latencyFrames) / input.rate + o.inputOffsetMs / 1000
    let playRate = 48_000.0
    let train = plan.render(rate: playRate)
    let clickRel = plan.times(rate: playRate)
    let lastClick = clickRel.last ?? 0
    // Record from before the train starts until a full click spacing (plus a second) after the last click.
    let recordSeconds = 0.8 + lastClick + plan.interval + 1.0
    print("input:   \"\(input.name)\" @ \(Int(input.rate)) Hz, \(input.channels) ch, input latency \(String(format: "%.1f", inputLatency * 1000)) ms compensated")
    print("playing: \(plan.clicks) clicks, \(Int(plan.interval * 1000)) ms apart, to the default output (~\(Int(recordSeconds)) s)")

    let recorder = InputRecorder(device: input, seconds: recordSeconds + 1)
    try recorder.start()
    defer { _ = recorder.stop() }
    Thread.sleep(forTimeInterval: 0.3)
    guard recorder.callbacks > 0 else { throw MeasureError("\"\(input.name)\" delivered no audio") }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: playRate, channels: 1)!
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(train.count))!
    pcm.frameLength = AVAudioFrameCount(train.count)
    train.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: train.count) }
    player.scheduleBuffer(pcm, at: nil, options: [], completionHandler: nil)
    engine.prepare()
    try engine.start()
    let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.5)
    player.play(at: AVAudioTime(hostTime: startHost))
    let playStart = AVAudioTime.seconds(forHostTime: startHost)

    Thread.sleep(forTimeInterval: max(0, recordSeconds - 0.3))
    player.stop()
    engine.stop()
    let samples = recorder.stop()

    // Sample 0 of the recording is the first IOProc buffer, taken at its host time minus the input latency.
    let recordStart = AVAudioTime.seconds(forHostTime: recorder.firstHostTime) - inputLatency
    let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
    print("recorded \(String(format: "%.1f", Double(samples.count) / input.rate)) s, peak \(String(format: "%.3f", peak))" +
          (recorder.gaps > 0 ? ", \(recorder.gaps) gaps in the input" : ""))
    if let wav = o.wav { try writeMonoWav(samples, rate: input.rate, to: wav); print("wrote \(wav.path)") }
    if peak < 0.002 { print("WARNING: the recording is silent. Is the microphone allowed for this terminal, and is the right input selected (--input)?") }
    if peak > 0.98 { print("WARNING: the recording clipped. Move the phone away from the mic or lower the volume.") }

    let report = Detector.analyze(samples: samples, rate: input.rate, recordStart: recordStart,
                                  clickTimes: clickRel.map { playStart + $0 }, slotLength: plan.interval, threshold: o.threshold)
    printReport(report, total: plan.clicks)
    if report.detected == 0 {
        print("""
        No clicks came back from the phone. Check that the phone is connected and playing in Halltone
        (the Mac app only captures while a phone is listening), that the phone's output is audible and
        held against the mic, and that you didn't mute the phone.
        """)
    } else if report.detected * 2 < plan.clicks {
        print("Fewer than half the clicks were found: hold the phone closer to the mic, or try --level 0.8.")
    }
    if let worst = report.delays.max(), worst > plan.interval * 1000 * 0.8 {
        print("WARNING: delays approach the click spacing, so a click may be matched with the wrong slot. Use a larger --interval.")
    }
}
