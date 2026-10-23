import Foundation
import AppKit
import ServiceManagement
import Combine
import os
import HalltoneCore
import HalltoneSender

private let log = Logger(subsystem: Constants.logSubsystem, category: "App")

@MainActor
final class SenderModel: ObservableObject {
    private enum Key {
        static let mute = "muteWhileStreaming"
        static let codec = "codec"
        static let port = "port"
        static let pairingCode = "pairingCode"
    }

    /// Slow-changing status (subscriber names, capture state, errors): always published.
    @Published private(set) var stats = Sender.Stats()
    /// Per-second numbers: only pushed to SwiftUI while the panel is open, so an idle menu bar
    /// app doesn't re-render every second.
    @Published private(set) var liveStats = Sender.Stats()
    @Published private(set) var startError: String?
    /// Whether headphone/lock-screen controls work (Accessibility permission granted).
    @Published private(set) var controlsEnabled = MediaKeys.isTrusted
    /// A listening phone asked to keep its headphones (see HeadphoneGuard).
    @Published private(set) var holdingHeadphones = false
    private let headphoneGuard = HeadphoneGuard()
    private lazy var beacon = ProximityBeacon(name: macName)
    private let phoneLogs = PhoneLogReceiver()
    private var permissionTimer: Timer?
    var panelVisible = false {
        didSet {
            if panelVisible {
                liveStats = latest
                refreshControlsEnabled()
            }
        }
    }
    private var latest = Sender.Stats()
    @Published var muteWhileStreaming: Bool {
        didSet { defaults.set(muteWhileStreaming, forKey: Key.mute); restart() }
    }
    @Published var codec: CodecID {
        didSet { defaults.set(Int(codec.rawValue), forKey: Key.codec); restart() }
    }
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }
    @Published private(set) var pairingCode: UInt32

    let port: UInt16
    var isStreaming: Bool { !stats.subscribers.isEmpty }
    var macName: String { Host.current().localizedName ?? "Mac" }

    private let defaults = UserDefaults.standard
    private var sender: Sender?

    init() {
        // On unless turned off: while a phone listens, sound from the Mac's own speakers is just
        // a delayed echo of what's in your ears. The tap mutes only while capturing, so the Mac
        // is audible again as soon as no phone is connected.
        muteWhileStreaming = defaults.object(forKey: Key.mute) as? Bool ?? true
        codec = CodecID(rawValue: UInt8(defaults.integer(forKey: Key.codec))) ?? .opus
        port = UInt16(defaults.integer(forKey: Key.port)) == 0 ? Constants.defaultPort : UInt16(defaults.integer(forKey: Key.port))
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let stored = UInt32(defaults.integer(forKey: Key.pairingCode))
        if stored == 0 {
            pairingCode = UInt32.random(in: 1000...9999)
            defaults.set(Int(pairingCode), forKey: Key.pairingCode)
        } else {
            pairingCode = stored
        }
        start()
    }

    func start() {
        var cfg = Sender.Config()
        cfg.port = port
        cfg.codec = codec
        cfg.pairingCode = pairingCode
        cfg.macName = macName
        let mute = muteWhileStreaming
        let s = Sender(config: cfg) {
            ProcessTapSource(muteWhileTapped: mute, excludedProcesses: [getpid()])
        }
        s.onStats = { [weak self] st in
            DispatchQueue.main.async {
                guard let self else { return }
                self.latest = st
                if self.panelVisible { self.liveStats = st }
                var slow = st
                slow.packetsPerSecond = 0; slow.kilobitsPerSecond = 0
                slow.subscribers = st.subscribers.map { var x = $0; x.bufferMs = 0; x.lossPermille = 0; x.lastSeen = .distantPast; return x }
                if self.stats != slow { self.stats = slow }
            }
        }
        s.onControl = { [weak s] cmd in
            // Called on the sender's receive thread; posting media keys is fine off-main.
            // Pause/play press the toggle key only if it would change anything: something is
            // "playing" if the capture heard it in the last 2 s.
            let playing = s?.isPlaying() ?? false
            switch cmd {
            case .pause where !playing, .play where playing:
                log.notice("\(String(describing: cmd), privacy: .public): already \(playing ? "playing" : "paused", privacy: .public); no key press")
                return MediaKeys.isTrusted
            default:
                return MediaKeys.send(cmd)
            }
        }
        s.controlsAvailable = { MediaKeys.isTrusted }
        s.canHoldHeadphones = { HeadphoneGuard.available }
        s.userAtMac = { UserPresence.isAtMac }
        s.userInputRecent = { UserPresence.inputRecent }
        s.onHoldHeadphones = { [weak self] on in
            DispatchQueue.main.async {
                self?.headphoneGuard.holding = on
                self?.holdingHeadphones = on
            }
        }
        let audible = s.lastAudibleUptimeNs
        headphoneGuard.lastAudibleUptimeNs = { audible.load() }
        headphoneGuard.isStreamingSource = { [weak s] in s?.hasListeningSubscriber ?? false }
        phoneLogs.pairingCode = pairingCode
        phoneLogs.start()
        do {
            try s.start()
            beacon.start()
            startError = nil
        } catch {
            startError = "\(error)"
            log.error("sender start failed: \(error)")
        }
        sender = s
    }

    func restart() {
        headphoneGuard.holding = false
        holdingHeadphones = false
        sender?.stop()
        sender = nil
        start()
    }

    /// "Turn On…" in the menu: explain, open System Settings, then watch for the switch to flip.
    func enableHeadphoneControls() {
        MediaKeys.requestPermission()
        permissionTimer?.invalidate()
        var checks = 0
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                checks += 1
                self?.refreshControlsEnabled()
                if self?.controlsEnabled == true || checks > 300 { t.invalidate() }
            }
        }
    }

    func refreshControlsEnabled() {
        let now = MediaKeys.isTrusted
        if now != controlsEnabled { controlsEnabled = now }
    }

    func regeneratePairingCode() {
        pairingCode = UInt32.random(in: 1000...9999)
        defaults.set(Int(pairingCode), forKey: Key.pairingCode)
        restart()
    }

    func openAudioCapturePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func quit() {
        sender?.stop()
        NSApplication.shared.terminate(nil)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("launch at login: \(error)")
        }
    }
}
