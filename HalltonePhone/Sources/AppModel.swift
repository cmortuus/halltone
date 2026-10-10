import Foundation
import Network
import AVFoundation
import MediaPlayer
import UIKit
import Combine
import os
import HalltoneCore
import HalltoneReceiver

private let log = Logger(subsystem: Constants.logSubsystem, category: "App")

/// Notice-level log, also appended to Documents/halltone.log. Developers pull it with
/// scripts/phone-log.sh (development-signed builds); users share it from the About section.
func diag(_ message: String) {
    log.notice("\(message, privacy: .public)")
    DiagFile.shared.append(message)
}

final class DiagFile {
    static let shared = DiagFile()
    private let queue = DispatchQueue(label: "com.halltone.diagfile")
    let url: URL
    private let formatter: DateFormatter

    private init() {
        url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("halltone.log")
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    func append(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { [url] in
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > 1_000_000 {
                try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("old.log"))
                try? FileManager.default.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("old.log"))
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

struct MacEntry: Identifiable, Hashable, Codable {
    enum Kind: String, Codable { case bonjour, manual }
    var id: String
    var name: String
    var kind: Kind
    var host: String = ""
    var port: UInt16 = Constants.defaultPort

    static func bonjour(name: String) -> MacEntry { MacEntry(id: "bonjour:\(name)", name: name, kind: .bonjour) }
    static func manual(host: String, port: UInt16) -> MacEntry {
        MacEntry(id: "manual:\(host):\(port)", name: "\(host):\(port)", kind: .manual, host: host, port: port)
    }

    var endpoint: NWEndpoint {
        switch kind {
        case .bonjour: return .service(name: name, type: Constants.serviceType, domain: "local.", interface: nil)
        case .manual: return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 47800)
        }
    }

    /// Key under which the pairing code is stored.
    var pairingKey: String { kind == .bonjour ? name : id }
}

@MainActor
final class AppModel: ObservableObject {
    private enum Key {
        static let manual = "manualMacs"
        static let autoConnect = "autoConnect"
        static let lastMac = "lastMac"
    }

    @Published private(set) var discovered: [MacEntry] = []
    @Published private(set) var manual: [MacEntry] = []
    @Published private(set) var selected: MacEntry?
    @Published private(set) var state: Receiver.State = .idle
    @Published private(set) var stats = Receiver.Stats()
    @Published private(set) var paused = false
    @Published var autoConnect: Bool { didSet { defaults.set(autoConnect, forKey: Key.autoConnect) } }
    @Published var pairingPrompt: MacEntry?
    @Published var pairingInput = ""
    @Published var pairingError: String?
    @Published var errorText: String?

    var allMacs: [MacEntry] { discovered + manual }
    var isActive: Bool { state.isActive }

    let playback = PlaybackEngine()
    private let receiver: Receiver
    private let defaults = UserDefaults.standard
    private var browser: NWBrowser?
    private var pauseTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var autoConnectPending: String?
    private var observers: [NSObjectProtocol] = []

    init() {
        receiver = Receiver(sink: playback)
        autoConnect = defaults.object(forKey: Key.autoConnect) as? Bool ?? true
        if let data = defaults.data(forKey: Key.manual), let list = try? JSONDecoder().decode([MacEntry].self, from: data) {
            manual = list
        }
        receiver.onState = { [weak self] st in Task { @MainActor in self?.handleState(st) } }
        receiver.onMacStatus = { [weak self] flags in
            guard flags.contains(.lastControlFailed) else { return }
            Task { @MainActor in self?.controlFailed() }
        }
        receiver.onStats = { [weak self] s in
            Task { @MainActor in
                self?.stats = s
                if s.state.isActive, Self.shouldLogStats() {
                    diag("stats buf=\(s.bufferMs)/\(s.targetMs) loss=\(s.lossPercent)% pps=\(s.packetsPerSecond) under=\(s.underruns) cb=\(s.callbackFrames) gap=\(s.arrivalGapMs) engine=\(self?.playback.engine.isRunning ?? false)")
                }
            }
        }
        diag("launch (build \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
        configureAudioSession()
        observeAudioSession()
        let nc = NotificationCenter.default
        for (name, label) in [(UIApplication.didEnterBackgroundNotification, "background"),
                              (UIApplication.willEnterForegroundNotification, "foreground"),
                              (UIApplication.willTerminateNotification, "terminate"),
                              (UIApplication.protectedDataWillBecomeUnavailableNotification, "locked"),
                              (UIApplication.protectedDataDidBecomeAvailableNotification, "unlocked")] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in diag("app \(label)") })
        }
        setupRemoteCommands()
        startBrowsing()
        if autoConnect, let last = defaults.string(forKey: Key.lastMac) {
            if let m = manual.first(where: { $0.id == last }) { connect(m) } else { autoConnectPending = last }
        }
    }

    // MARK: - Connect / disconnect

    func connect(_ mac: MacEntry) {
        pairingError = nil
        guard let code = Keychain.pairingCode(for: mac.pairingKey) ?? Self.debugPairingCode() else {
            pairingInput = ""
            pairingPrompt = mac
            return
        }
        connect(mac, code: code)
    }

    /// Debug builds only: `-pairingCode 1234` as a launch argument (or HALLTONE_PAIRING_CODE in the
    /// environment) stands in for the Keychain, for automated Simulator runs. Compiled out of Release.
    /// Per-second stats in Debug builds; every 10 s in Release to keep the log small.
    private static var statsCounter = 0
    private static func shouldLogStats() -> Bool {
        #if DEBUG
        return true
        #else
        statsCounter += 1
        return statsCounter % 10 == 1
        #endif
    }

    /// URL of the diagnostics log, for the in-app share button.
    var diagnosticsURL: URL { DiagFile.shared.url }

    private static func debugPairingCode() -> UInt32? {
        #if DEBUG
        return UInt32(ProcessInfo.processInfo.environment["HALLTONE_PAIRING_CODE"] ?? "")
            ?? UserDefaults.standard.string(forKey: "pairingCode").flatMap(UInt32.init)
        #else
        return nil
        #endif
    }

    func submitPairingCode() {
        guard let mac = pairingPrompt, let code = UInt32(pairingInput.trimmingCharacters(in: .whitespaces)) else {
            pairingError = "Enter the 4-digit code shown in the Halltone menu on your Mac."
            return
        }
        Keychain.save(pairingCode: code, for: mac.pairingKey)
        pairingPrompt = nil
        connect(mac, code: code)
    }

    private func connect(_ mac: MacEntry, code: UInt32) {
        diag("connect → \(mac.name)")
        selected = mac
        defaults.set(mac.id, forKey: Key.lastMac)
        autoConnectPending = nil
        paused = false
        pauseTask?.cancel()
        activateAudioSession()
        receiver.connect(to: mac.endpoint, pairingCode: code, deviceName: UIDevice.current.name)
        updateNowPlaying(macName: mac.name)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func disconnect() {
        diag("disconnect requested")
        pauseTask?.cancel()
        paused = false
        receiver.disconnect()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func toggle() {
        if isActive { disconnect() } else if let s = selected ?? allMacs.first { connect(s) }
    }

    func select(_ mac: MacEntry) { selected = mac }

    func addManual(host: String, port: UInt16) {
        let entry = MacEntry.manual(host: host.trimmingCharacters(in: .whitespaces), port: port)
        guard !manual.contains(entry) else { return }
        manual.append(entry)
        persistManual()
        selected = entry
    }

    func removeManual(_ entry: MacEntry) {
        manual.removeAll { $0.id == entry.id }
        persistManual()
        if selected == entry { selected = nil }
    }

    func forgetPairing(_ mac: MacEntry) { Keychain.delete(for: mac.pairingKey) }

    private func persistManual() {
        if let data = try? JSONEncoder().encode(manual) { defaults.set(data, forKey: Key.manual) }
    }

    private func handleState(_ st: Receiver.State) {
        diag("state: \(st)")
        state = st
        switch st {
        case .rejected(let why):
            if let mac = selected {
                Keychain.delete(for: mac.pairingKey)
                pairingError = why
                pairingInput = ""
                pairingPrompt = mac
            }
        case .failed(let why):
            errorText = why
        case .subscribed(let name):
            updateNowPlaying(macName: name)
        default: break
        }
    }

    // MARK: - Discovery

    private func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: Constants.serviceType, domain: nil), using: params)
        b.stateUpdateHandler = { st in log.info("browser: \(String(describing: st), privacy: .public)") }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let names: [String] = results.compactMap {
                if case .service(let name, _, _, _) = $0.endpoint { return name }
                return nil
            }
            Task { @MainActor in self?.updateDiscovered(names.sorted()) }
        }
        b.start(queue: .global(qos: .utility))
        browser = b
    }

    private func updateDiscovered(_ names: [String]) {
        discovered = names.map(MacEntry.bonjour)
        if selected == nil { selected = discovered.first ?? manual.first }
        if let pending = autoConnectPending, let m = discovered.first(where: { $0.id == pending }) {
            autoConnectPending = nil
            connect(m)
        }
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: [])
            try s.setPreferredSampleRate(Constants.sampleRate)
            try s.setPreferredIOBufferDuration(0.005)
        } catch {
            log.error("audio session config: \(error)")
        }
    }

    private func activateAudioSession() {
        do { try AVAudioSession.sharedInstance().setActive(true) } catch { log.error("session activate: \(error)") }
    }

    private func observeAudioSession() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in self?.handleInterruption(n) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in self?.handleRouteChange(n) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildEngine(reason: "media services reset") }
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                diag("engine configuration change")
                self?.rebuildEngine(reason: "engine configuration change")
            }
        })
    }

    private func handleInterruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            diag("interruption began")
            playback.muted = true
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(rawValue: n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            diag("interruption ended (resume=\(opts.contains(.shouldResume)))")
            if opts.contains(.shouldResume), isActive { rebuildEngine(reason: "interruption ended") }
        @unknown default: break
        }
    }

    private func handleRouteChange(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        diag("route change \(reason.rawValue) → \(outputs) engine running=\(playback.engine.isRunning)")
        switch reason {
        case .oldDeviceUnavailable:
            guard isActive else { return }
            diag("output device went away; pausing (subscription kept for 60 s)")
            paused = true
            playback.muted = true
            pauseTask?.cancel()
            pauseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, self.paused else { return }
                log.notice("paused for 60 s; disconnecting")
                self.disconnect()
            }
        case .newDeviceAvailable:
            if paused { resume() } else if isActive, !playback.engine.isRunning { rebuildEngine(reason: "new device, engine stopped") }
        default:
            // Any other route change that stopped the engine (e.g. category/override changes).
            if isActive, !paused, !playback.engine.isRunning { rebuildEngine(reason: "route change \(reason.rawValue)") }
        }
    }

    func resume() {
        pauseTask?.cancel()
        paused = false
        playback.muted = false
        if isActive { rebuildEngine(reason: "resume") }
    }

    /// Restart the engine, retrying with backoff: right after a route change the session can
    /// refuse for a moment, and an engine that stays stopped gets the app suspended in the
    /// background (which is what breaks the stream).
    private func rebuildEngine(reason: String) {
        guard isActive else { return }
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            let delays: [Double] = [0, 0.25, 0.5, 1, 2, 4]
            for (attempt, delay) in delays.enumerated() {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled, let self, self.isActive else { return }
                self.activateAudioSession()
                do {
                    try self.playback.restart()
                    if !self.paused { self.playback.muted = false }
                    diag("engine restarted (\(reason), attempt \(attempt + 1))")
                    return
                } catch {
                    diag("engine restart failed (\(reason), attempt \(attempt + 1)): \(error)")
                }
            }
        }
    }

    // MARK: - Lock screen

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.remote(.playPause) ?? .commandFailed }
        c.pauseCommand.addTarget { [weak self] _ in self?.remote(.playPause) ?? .commandFailed }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.remote(.playPause) ?? .commandFailed }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.remote(.next) ?? .commandFailed }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.remote(.previous) ?? .commandFailed }
    }

    private func remote(_ cmd: ControlCommand) -> MPRemoteCommandHandlerStatus {
        guard isActive else { return .noActionableNowPlayingItem }
        if paused { resume() }
        receiver.sendControl(cmd)
        return .success
    }

    /// A headphone/lock-screen press reached the Mac but it can't press keys yet. The user is
    /// probably away from both screens, so say so where they'll look: the lock screen.
    @Published private(set) var showControlsHelpBanner = false
    private var nowPlayingRestore: Task<Void, Never>?

    private func controlFailed() {
        diag("control failed on Mac: headphone controls are off there")
        showControlsHelpBanner = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Pause isn't set up yet",
            MPMediaItemPropertyArtist: "Turn on Headphone Controls in Halltone on your Mac",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        nowPlayingRestore?.cancel()
        nowPlayingRestore = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            self.updateNowPlaying(macName: self.stats.macName.isEmpty ? (self.selected?.name ?? "Mac") : self.stats.macName)
        }
    }

    func dismissControlsHelpBanner() { showControlsHelpBanner = false }

    private func updateNowPlaying(macName: String) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Halltone",
            MPMediaItemPropertyArtist: macName,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
    }
}
