import Foundation
import CoreAudio
import CoreBluetooth
import IOBluetooth
import os
import HalltoneCore
import HalltoneSender

private let log = Logger(subsystem: Constants.logSubsystem, category: "Headphones")

/// "Keep headphones on this iPhone", turned on from the phone while it listens.
///
/// macOS moves AirPods between a Mac and an iPhone on its own ("automatic switching"). While a
/// phone is listening that fights the user: the Mac grabs the AirPods back whenever it plays.
/// This watches the Mac's default output and:
/// - when Bluetooth headphones become the Mac's output, switches the Mac back to its speakers and
///   drops the Mac's Bluetooth link to them, so they return to the phone;
/// - when headphones leave the Mac and that paused what was playing (browsers and Music pause
///   when headphones disconnect), presses play once so the stream carries on.
@MainActor
final class HeadphoneGuard {
    /// On while some subscribed phone asks for it.
    var holding = false {
        didSet {
            guard holding != oldValue else { return }
            log.notice("keep headphones on phone: \(self.holding ? "on" : "off", privacy: .public)")
            if holding { requestBluetoothPermissionIfNeeded() }
        }
    }
    /// Last time the capture heard something (uptime ns), from the sender.
    var lastAudibleUptimeNs: () -> UInt64 = { 0 }

    private var currentDefault: AudioDeviceID = 0
    private var currentIsBluetooth = false
    private var kicks: [Date] = []
    private var resumeTask: Task<Void, Never>?
    private var bluetoothPermission: CBCentralManager?

    init() {
        currentDefault = Self.defaultOutput()
        currentIsBluetooth = Self.isBluetooth(currentDefault)
        var addr = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultOutputChanged() }
        }
    }

    /// Whether this Mac can do it at all (Bluetooth permission not refused).
    nonisolated static var available: Bool { CBManager.authorization != .denied && CBManager.authorization != .restricted }

    private func defaultOutputChanged() {
        let new = Self.defaultOutput()
        let wasBluetooth = currentIsBluetooth
        let isBluetooth = Self.isBluetooth(new)
        currentDefault = new
        currentIsBluetooth = isBluetooth
        guard holding else { return }
        if isBluetooth && !wasBluetooth {
            sendHeadphonesBack(new)
        } else if wasBluetooth && !isBluetooth {
            resumeIfPausedByDisconnect()
        }
    }

    /// The Mac just took the headphones while the phone is listening: give them back.
    private func sendHeadphonesBack(_ device: AudioDeviceID) {
        let now = Date()
        kicks = kicks.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard kicks.count <= 4 else {
            // Something keeps handing them back to the Mac; don't fight it in a loop.
            log.error("headphones keep returning to the Mac; leaving them there")
            return
        }
        let name = Self.name(device)
        log.notice("Mac took \(name, privacy: .public) while the phone is listening; sending them back")
        if let speakers = SilenceKeeper.quietOutputDevice() {
            Self.setDefaultOutput(speakers.id)
        }
        // Core Audio UIDs of Bluetooth outputs start with the device address ("40-B3-FA-…:output").
        guard let uid = Self.uid(device), let address = uid.split(separator: ":").first,
              let bt = IOBluetoothDevice(addressString: String(address)) else {
            log.error("no Bluetooth address for \(name, privacy: .public)")
            return
        }
        let err = bt.closeConnection()
        if err != kIOReturnSuccess { log.error("disconnect \(name, privacy: .public) failed: \(err)") }
    }

    /// Headphones left the Mac. If something was playing right before and the capture has been
    /// silent since, the app paused itself on the disconnect: press play once.
    private func resumeIfPausedByDisconnect() {
        let changedAt = DispatchTime.now().uptimeNanoseconds
        guard changedAt &- lastAudibleUptimeNs() < 1_500_000_000 else { return }
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled, self.holding else { return }
            // Allow 0.5 s for the tap to swap devices; anything audible after that means it's
            // still playing and pressing play/pause would pause it.
            guard self.lastAudibleUptimeNs() < changedAt + 500_000_000 else { return }
            if MediaKeys.send(.playPause) {
                log.notice("playback paused when the headphones left; resumed it")
            } else {
                log.notice("playback paused when the headphones left; can't resume (headphone controls off)")
            }
        }
    }

    private func requestBluetoothPermissionIfNeeded() {
        // Disconnecting a device needs the Bluetooth permission; ask now, not mid-swap.
        if CBManager.authorization == .notDetermined, bluetoothPermission == nil {
            bluetoothPermission = CBCentralManager(delegate: nil, queue: nil)
        }
    }

    // MARK: - Core Audio

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    private static func defaultOutput() -> AudioDeviceID {
        var addr = defaultOutputAddress
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static func setDefaultOutput(_ id: AudioDeviceID) {
        var addr = defaultOutputAddress
        var dev = id
        let err = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                             UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
        if err != noErr { log.error("set default output failed: \(err)") }
    }

    private static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        return err == noErr ? value as String : nil
    }

    private static func uid(_ id: AudioDeviceID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }
    private static func name(_ id: AudioDeviceID) -> String { string(id, kAudioObjectPropertyName) ?? "headphones" }
}
