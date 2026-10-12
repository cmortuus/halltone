#if os(macOS)
import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import os
import HalltoneCore

private let log = Logger(subsystem: Constants.logSubsystem, category: "SilenceKeeper")

/// Plays silence while capturing so the process tap's IO starts immediately (a tap with no
/// active writers waits indefinitely). Our own process is excluded from the tap.
///
/// The silence goes to a built-in (or other wired) output, never the default device: if the
/// default output is Bluetooth headphones that the user has moved to the iPhone, holding an
/// active stream to them from the Mac makes the two devices fight over the headphones.
public final class SilenceKeeper {
    private var engine: AVAudioEngine?
    private var node: AVAudioSourceNode?

    func start() {
        guard engine == nil else { return }
        guard let device = Self.quietOutputDevice() else {
            log.notice("silence keeper: no wired output device; skipping")
            return
        }
        let e = AVAudioEngine()
        if let unit = e.outputNode.audioUnit {
            var dev = device.id
            let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if err != noErr {
                log.error("silence keeper: could not select \(device.name, privacy: .public) (\(err)); skipping")
                return
            }
        }
        let fmt = e.outputNode.outputFormat(forBus: 0)
        let n = AVAudioSourceNode(format: fmt) { isSilence, _, _, abl in
            for b in UnsafeMutableAudioBufferListPointer(abl) { memset(b.mData, 0, Int(b.mDataByteSize)) }
            isSilence.pointee = true
            return noErr
        }
        e.attach(n)
        e.connect(n, to: e.mainMixerNode, format: fmt)
        e.mainMixerNode.outputVolume = 0
        do {
            try e.start()
            engine = e
            node = n
            log.notice("silence keeper started on \(device.name, privacy: .public)")
        } catch {
            log.error("silence keeper failed: \(error)")
        }
    }

    func stop() {
        guard let e = engine else { return }
        e.stop()
        if let n = node { e.detach(n) }
        engine = nil
        node = nil
        log.notice("silence keeper stopped")
    }

    /// First output device that is built in, else any wired (non-Bluetooth, non-virtual,
    /// non-aggregate, non-AirPlay) output.
    public static func quietOutputDevice() -> (id: AudioDeviceID, name: String)? {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return nil }

        var candidates: [(id: AudioDeviceID, name: String, builtIn: Bool)] = []
        for id in ids {
            var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                   mScope: kAudioObjectPropertyScopeOutput,
                                                   mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 else { continue }
            var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport) == noErr else { continue }
            let excluded: Set<UInt32> = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
                                         kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                                         kAudioDeviceTransportTypeAutoAggregate, kAudioDeviceTransportTypeAirPlay,
                                         kAudioDeviceTransportTypeContinuityCaptureWired,
                                         kAudioDeviceTransportTypeContinuityCaptureWireless]
            guard !excluded.contains(transport) else { continue }
            var nAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            var name: CFString = "" as CFString
            var nSize = UInt32(MemoryLayout<CFString>.size)
            _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(id, &nAddr, 0, nil, &nSize, $0) }
            candidates.append((id, name as String, transport == kAudioDeviceTransportTypeBuiltIn))
        }
        let pick = candidates.first(where: \.builtIn) ?? candidates.first
        return pick.map { ($0.id, $0.name) }
    }
}
#endif
