#if os(macOS)
import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import os
import HalltoneCore

private let log = Logger(subsystem: Constants.logSubsystem, category: "ProcessTap")

/// Captures all system audio with a Core Audio process tap (macOS 14.2+) attached to a
/// private aggregate device. Samples arrive interleaved Float32 at the output device's rate.
@available(macOS 14.2, *)
public final class ProcessTapSource: AudioSource {
    public enum Failure: Error, CustomStringConvertible {
        case createTap(OSStatus)
        case readTapFormat(OSStatus)
        case defaultOutputDevice(OSStatus)
        case createAggregate(OSStatus)
        case createIOProc(OSStatus)
        case start(OSStatus)
        case unsupportedFormat(String)

        public var description: String {
            switch self {
            case .createTap(let s): return "AudioHardwareCreateProcessTap failed (\(s)). On macOS 14.4+ this needs the System Audio Recording permission."
            case .readTapFormat(let s): return "Reading kAudioTapPropertyFormat failed (\(s))"
            case .defaultOutputDevice(let s): return "Reading default output device failed (\(s))"
            case .createAggregate(let s): return "AudioHardwareCreateAggregateDevice failed (\(s))"
            case .createIOProc(let s): return "AudioDeviceCreateIOProcIDWithBlock failed (\(s))"
            case .start(let s): return "AudioDeviceStart failed (\(s))"
            case .unsupportedFormat(let f): return "Unsupported tap format: \(f)"
            }
        }
    }

    public private(set) var format: AVAudioFormat?
    public var dataAvailable: DispatchSemaphore?
    public let muteWhileTapped: Bool
    /// Processes (pids) to exclude from the tap, e.g. our own process.
    public let excludedProcesses: [pid_t]

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var ring: RingBuffer?
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchCapacity = 0
    private var channels = 2
    private var interleaved = true
    private let ioQueue = DispatchQueue(label: "com.halltone.tap.io", qos: .userInteractive)
    private var running = false
    private let keeper = SilenceKeeper()

    /// When true (default) the aggregate contains only the tap. Including the default output
    /// device as a sub-device makes AudioDeviceStart block until that device is awake and
    /// something is playing (tens of seconds with a Bluetooth output), and audio that starts
    /// later is never delivered. A tap-only aggregate starts in ~150 ms and delivers audio as
    /// soon as any process plays.
    public let tapOnly: Bool
    /// kAudioAggregateDeviceTapAutoStartKey.
    public let autoStart: Bool

    public init(muteWhileTapped: Bool = false, excludedProcesses: [pid_t] = [], tapOnly: Bool = true, autoStart: Bool = true) {
        self.muteWhileTapped = muteWhileTapped
        self.excludedProcesses = excludedProcesses
        self.tapOnly = tapOnly
        self.autoStart = autoStart
    }

    deinit { stop() }

    public func start(into ring: RingBuffer) throws {
        guard !running else { return }
        self.ring = ring
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

        // 1. Process tap: global stereo mix of everything the system plays.
        let objectIDs: [AudioObjectID] = try excludedProcesses.compactMap { pid in
            let obj = try Self.processObjectID(forPID: pid)
            return obj == kAudioObjectUnknown ? nil : obj
        }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: objectIDs)
        desc.uuid = UUID()
        desc.name = "Halltone"
        desc.isPrivate = true
        desc.muteBehavior = muteWhileTapped ? CATapMuteBehavior.mutedWhenTapped : CATapMuteBehavior.unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr, tap != kAudioObjectUnknown else { throw Failure.createTap(err) }
        tapID = tap
        log.notice("tap created after \(ms()) ms")

        // 2. Tap format.
        var asbd = AudioStreamBasicDescription()
        err = Self.getProperty(tapID, kAudioTapPropertyFormat, &asbd)
        guard err == noErr else { teardown(); throw Failure.readTapFormat(err) }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard asbd.mFormatID == kAudioFormatLinearPCM, isFloat, asbd.mBitsPerChannel == 32 else {
            teardown(); throw Failure.unsupportedFormat("\(asbd)")
        }
        interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        channels = Int(asbd.mChannelsPerFrame)
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate,
                                      channels: AVAudioChannelCount(channels), interleaved: true) else {
            teardown(); throw Failure.unsupportedFormat("\(asbd)")
        }
        format = fmt
        log.notice("tap format: \(asbd.mSampleRate, privacy: .public) Hz, \(self.channels) ch, interleaved=\(self.interleaved)")

        // 3. Private aggregate device containing the default output device + the tap.
        let outputUID: String
        do { outputUID = try Self.defaultOutputDeviceUID() } catch { teardown(); throw error }
        var aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Halltone Tap",
            kAudioAggregateDeviceUIDKey: "com.halltone.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: autoStart,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        if !tapOnly {
            aggDesc[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggDesc[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard err == noErr, agg != kAudioObjectUnknown else { teardown(); throw Failure.createAggregate(err) }
        aggregateID = agg
        log.notice("aggregate created after \(ms()) ms (tapOnly=\(self.tapOnly))")
        Self.setSmallIOBuffer(aggregateID)

        // 4. Scratch for de-interleaving (only used if the tap is non-interleaved).
        if !interleaved {
            scratchCapacity = 8192 * channels
            scratch = .allocate(capacity: scratchCapacity)
        }

        // 5. Keep a writer alive so the tap's IO starts now rather than "after waiting for writers".
        keeper.start()

        // 6. IOProc. Real-time: copy into the ring and nothing else.
        var pid: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&pid, aggregateID, ioQueue) { [self] _, inInputData, _, _, _ in
            handleInput(inInputData)
        }
        guard err == noErr, let pid else { teardown(); throw Failure.createIOProc(err) }
        procID = pid

        err = AudioDeviceStart(aggregateID, pid)
        guard err == noErr else { teardown(); throw Failure.start(err) }
        running = true
        log.notice("process tap started after \(ms()) ms (agg \(agg), tap \(tap))")
    }

    /// Human-readable description of the aggregate's input streams (for diagnostics).
    public func diagnostics() -> String {
        guard aggregateID != kAudioObjectUnknown else { return "not running" }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var out = "aggregate \(aggregateID) tap \(tapID): "
        guard AudioObjectGetPropertyDataSize(aggregateID, &addr, 0, nil, &size) == noErr else { return out + "no input config" }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, raw) == noErr else { return out + "read failed" }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        out += "\(list.count) input buffer(s):"
        for b in list { out += " [\(b.mNumberChannels) ch, \(b.mDataByteSize) B]" }
        var fmt = AudioStreamBasicDescription()
        var faddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                               mScope: kAudioObjectPropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
        var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(aggregateID, &faddr, 0, nil, &fsize, &fmt) == noErr {
            out += " format \(fmt.mSampleRate) Hz \(fmt.mChannelsPerFrame) ch flags 0x\(String(fmt.mFormatFlags, radix: 16)) bpf \(fmt.mBytesPerFrame)"
        }
        return out
    }

    public func stop() {
        guard running || tapID != kAudioObjectUnknown || aggregateID != kAudioObjectUnknown else { return }
        teardown()
        log.info("process tap stopped")
    }

    private func teardown() {
        running = false
        keeper.stop()
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        scratch?.deallocate()
        scratch = nil
        scratchCapacity = 0
        ring = nil
    }

    // MARK: Real-time path

    @inline(__always)
    private func handleInput(_ abl: UnsafePointer<AudioBufferList>) {
        guard let ring else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        if interleaved {
            guard list.count > 0, let data = list[0].mData else { return }
            let count = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            ring.write(data.assumingMemoryBound(to: Float.self), count: count)
            dataAvailable?.signal()
        } else {
            let n = list.count
            guard n > 0, let scratch else { return }
            let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            let total = frames * n
            guard total <= scratchCapacity else { return }
            for ch in 0..<n {
                guard let p = list[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                var o = ch
                for i in 0..<frames { scratch[o] = p[i]; o += n }
            }
            ring.write(scratch, count: total)
            dataAvailable?.signal()
        }
    }

    // MARK: Core Audio helpers

    /// Asks for 128-frame IO (2.7 ms) instead of the default 512 (10.7 ms): audio reaches the
    /// encoder sooner. Clamped to what the device allows.
    private static func setSmallIOBuffer(_ device: AudioObjectID, frames wanted: UInt32 = 128) {
        var rangeAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var frames = wanted
        if AudioObjectGetPropertyData(device, &rangeAddr, 0, nil, &size, &range) == noErr {
            frames = UInt32(min(max(Double(wanted), range.mMinimum), range.mMaximum))
        }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let err = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        log.notice("IO buffer \(frames) frames (status \(err))")
    }

    private static func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                       _ value: inout T) -> OSStatus {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    }

    public static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var dev = AudioDeviceID(kAudioObjectUnknown)
        let err = getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &dev)
        guard err == noErr, dev != kAudioObjectUnknown else { throw Failure.defaultOutputDevice(err) }
        return dev
    }

    static func defaultOutputDeviceUID() throws -> String {
        let dev = try defaultOutputDeviceID()
        var uid: CFString = "" as CFString
        let err = getProperty(dev, kAudioDevicePropertyDeviceUID, &uid)
        guard err == noErr else { throw Failure.defaultOutputDevice(err) }
        return uid as String
    }

    static func processObjectID(forPID pid: pid_t) throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &pidValue) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<pid_t>.size), p, &size, &object)
        }
        guard err == noErr else { return kAudioObjectUnknown }
        return object
    }
}
#endif
