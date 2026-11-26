#if os(macOS)
import Foundation
import CoreAudio
import HalltoneCore
@_exported import HalltoneSenderCore

/// The Mac sender: `SenderCore` plus Bonjour advertising and following the default output
/// device. Capture comes from the `source` factory (`ProcessTapSource`); resampling to 48 kHz is
/// done by the source's `AVAudioConverter` (see `ProcessTapSource.makeResampler`).
public final class Sender: SenderCore {
    private var deviceListenerInstalled = false

    public override func makeAdvertiser(txtValues: [String: String], queue: DispatchQueue) -> AnyObject? {
        BonjourAdvertiser(name: config.macName, port: config.port, txtValues: txtValues, queue: queue)
    }

    public override func installOutputDeviceListener(on queue: DispatchQueue) {
        guard !deviceListenerInstalled else { return }
        deviceListenerInstalled = true
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { [weak self] _, _ in
            self?.restartCapture()
        }
    }
}
#endif
