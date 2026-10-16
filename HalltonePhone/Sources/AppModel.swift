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
    /// From the Mac's Bonjour TXT record: its address on its preferred (wired) interface. A Mac on
    /// both Ethernet and Wi-Fi is reachable at two addresses; connecting to the wired one avoids a
    /// second wireless hop and the Mac's Wi-Fi/Bluetooth radio sharing. Not persisted.
    var preferredHost: String?
    /// Known from an earlier visit but not visible on the current network (e.g. away from home,
    /// reaching the Mac over a VPN at its remembered address). Not persisted.
    var away = false
    /// From the TXT record: the Mac's Tailscale address. Bonjour doesn't cross Tailscale, so it's
    /// remembered and used when the Mac isn't on the current network. Not persisted here.
    var tailscaleHost: String?
    /// Another address to try if `preferredHost` stops working (LAN ↔ Tailscale). Not persisted.
    var alternateHost: String?
    /// Reached over Tailscale rather than the local network.
    var viaTailscale: Bool { preferredHost != nil && preferredHost == tailscaleHost }

    static func bonjour(name: String, preferredHost: String? = nil, port: UInt16? = nil,
                        tailscaleHost: String? = nil) -> MacEntry {
        var e = MacEntry(id: "bonjour:\(name)", name: name, kind: .bonjour)
        e.preferredHost = preferredHost
        e.tailscaleHost = tailscaleHost
        if let port { e.port = port }
        return e
    }

    // Identity is the id alone, so a refreshed address doesn't make it a different Mac.
    static func == (a: MacEntry, b: MacEntry) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
    private enum CodingKeys: String, CodingKey { case id, name, kind, host, port }
    static func manual(host: String, port: UInt16) -> MacEntry {
        MacEntry(id: "manual:\(host):\(port)", name: "\(host):\(port)", kind: .manual, host: host, port: port)
    }

    var endpoint: NWEndpoint {
        switch kind {
        case .bonjour:
            if let preferredHost, let p = NWEndpoint.Port(rawValue: port) {
                return .hostPort(host: NWEndpoint.Host(preferredHost), port: p)
            }
            return .service(name: name, type: Constants.serviceType, domain: "local.", interface: nil)
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
        static let latencyMode = "latencyMode"
        static let keepHeadphones = "keepHeadphones"
        /// [Mac id: "host:port"]: last advertised address of each Bonjour Mac.
        static let knownAddresses = "knownAddresses"
        /// [Mac id: Tailscale IPv4]: from the TXT record, for reaching the Mac away from home.
        static let knownTailscale = "knownTailscale"
    }

    @Published private(set) var discovered: [MacEntry] = []
    @Published private(set) var manual: [MacEntry] = []
    @Published private(set) var selected: MacEntry?
    @Published private(set) var state: Receiver.State = .idle
    @Published private(set) var stats = Receiver.Stats()
    @Published private(set) var paused = false
    @Published var autoConnect: Bool { didSet { defaults.set(autoConnect, forKey: Key.autoConnect) } }
    @Published var latencyMode: LatencyMode {
        didSet {
            defaults.set(latencyMode.rawValue, forKey: Key.latencyMode)
            receiver.latencyMode = latencyMode
            diag("latency mode: \(latencyMode.rawValue)")
            updateProximity()
        }
    }
    /// Ask the Mac not to take the headphones back while this phone listens (and to resume
    /// playback if moving them paused it).
    @Published var keepHeadphones: Bool {
        didSet {
            defaults.set(keepHeadphones, forKey: Key.keepHeadphones)
            receiver.holdHeadphones = keepHeadphones
            diag("keep headphones on iPhone: \(keepHeadphones)")
        }
    }
    @Published var pairingPrompt: MacEntry?
    @Published var pairingInput = ""
    @Published var pairingError: String?
    @Published var errorText: String?

    var allMacs: [MacEntry] { discovered + rememberedAway + manual }

    /// Bonjour Macs seen before (with an address) that aren't on the current network.
    private var rememberedAway: [MacEntry] {
        knownAddresses.compactMap { id, hostPort -> MacEntry? in
            guard id.hasPrefix("bonjour:"), !discovered.contains(where: { $0.id == id }),
                  let (host, port) = Self.splitHostPort(hostPort) else { return nil }
            // Away from home the LAN address is only reachable over a VPN into the home network;
            // a Tailscale address works from anywhere both devices run Tailscale. Prefer it, and
            // keep the LAN address as the fallback (and vice versa).
            let ts = knownTailscale[id]
            var e = MacEntry.bonjour(name: String(id.dropFirst("bonjour:".count)), preferredHost: ts ?? host,
                                     port: port, tailscaleHost: ts)
            e.alternateHost = ts == nil ? nil : host
            e.away = true
            return e
        }.sorted { $0.name < $1.name }
    }

    @Published private var knownAddresses: [String: String] = [:]
    @Published private var knownTailscale: [String: String] = [:]

    private static func splitHostPort(_ s: String) -> (String, UInt16)? {
        guard let i = s.lastIndex(of: ":"), let p = UInt16(s[s.index(after: i)...]) else { return nil }
        return (String(s[..<i]), p)
    }
    var isActive: Bool { state.isActive }

    let playback = PlaybackEngine()
    private let receiver: Receiver
    private let defaults = UserDefaults.standard
    private var browser: NWBrowser?
    private var pauseTask: Task<Void, Never>?
    private let calls = CallWatcher()
    private var interruptionTask: Task<Void, Never>?
    /// Paused by an audio interruption that may never end (not a call, not a lost output):
    /// opening the app resumes it.
    private var pausedByInterruption = false
    /// Bluetooth signal strength to the Mac, for Auto latency.
    private let proximity = MacProximity()
    private var proximityRunning = false
    private var rebuildTask: Task<Void, Never>?
    private var autoConnectPending: String?
    private var observers: [NSObjectProtocol] = []

    init() {
        receiver = Receiver(sink: playback)
        autoConnect = defaults.object(forKey: Key.autoConnect) as? Bool ?? true
        knownAddresses = defaults.dictionary(forKey: Key.knownAddresses) as? [String: String] ?? [:]
        knownTailscale = defaults.dictionary(forKey: Key.knownTailscale) as? [String: String] ?? [:]
        latencyMode = defaults.string(forKey: Key.latencyMode).flatMap(LatencyMode.init(rawValue:)) ?? .auto
        keepHeadphones = defaults.bool(forKey: Key.keepHeadphones)
        receiver.latencyMode = latencyMode
        receiver.holdHeadphones = keepHeadphones
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
                self?.updateProximity()
                self?.syncNowPlayingRate()
                if s.state.isActive, Self.shouldLogStats() {
                    let rssi = self?.proximity.rssi.map { String(Int($0)) } ?? "-"
                    diag("stats atMac=\(s.atMac) near=\(s.phoneNearMac.map(String.init) ?? "-") rssi=\(rssi) active=\(s.macUserActive.map(String.init) ?? "-") input=\(s.macInputRecent.map(String.init) ?? "-") buf=\(s.bufferMs)/\(s.targetMs) loss=\(s.lossPercent)% pps=\(s.packetsPerSecond) under=\(s.underruns) cb=\(s.callbackFrames) gap=\(s.arrivalGapMs) maxgap10s=\(s.maxArrivalGapMs10s) timergap10s=\(s.maxTimerGapMs10s) bg=\(UIApplication.shared.applicationState == .background) primed=\(s.jitterPrimed) resets=\(s.jitterResets) queued=\(s.queuedMs) handoff=\(s.handoffMs) muted=\(self?.playback.muted ?? false) concealed=\(s.concealedFrames) late=\(s.lateFrames) trimmed=\(s.trimmedFrames) stretched=\(s.stretchedFrames) resendAsked=\(s.resendRequested) recovered=\(s.resendRecovered) engine=\(self?.playback.engine.isRunning ?? false)")
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
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                diag("app \(label)")
                if label == "foreground" { Task { @MainActor in self?.cameToForeground() } }
            })
        }
        setupRemoteCommands()
        calls.onChange = { [weak self] inCall in self?.callChanged(inCall) }
        startBrowsing()
        if autoConnect, let last = defaults.string(forKey: Key.lastMac) {
            if let m = manual.first(where: { $0.id == last }) {
                connect(m)
            } else if let m = rememberedAway.first(where: { $0.id == last }) {
                // Known address: connect right away (works at home and over a VPN); no need to
                // wait for Bonjour, which doesn't cross VPNs.
                connect(m)
            } else {
                autoConnectPending = last
            }
        }
    }

    // MARK: - Connect / disconnect

    func connect(_ requested: MacEntry) {
        let mac = discovered.first(where: { $0.id == requested.id })
            ?? rememberedAway.first(where: { $0.id == requested.id })
            ?? requested
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

    private var connectedID: String?
    private var connectedHost: String?
    /// The other address (LAN or Tailscale) to try if this one stops getting through.
    private var connectedAlternate: String?
    private var fallbackTask: Task<Void, Never>?

    private func connect(_ mac: MacEntry, code: UInt32) {
        connectedID = mac.id
        connectedHost = mac.preferredHost
        connectedAlternate = mac.alternateHost
        fallbackTask?.cancel()
        diag("connect → \(mac.name) via \(mac.preferredHost ?? (mac.kind == .manual ? mac.host : "Bonjour"))")
        selected = mac
        defaults.set(mac.id, forKey: Key.lastMac)
        autoConnectPending = nil
        paused = false
        receiver.listening = true
        pauseTask?.cancel()
        interruptionTask?.cancel()
        pausedByInterruption = false
        // A previous session may have ended muted (headphones away, interruption); a muted
        // engine never reads the hand-off ring, so the new stream would never start playing.
        playback.muted = calls.inCall
        configureAudioSession()
        activateAudioSession()
        receiver.connect(to: mac.endpoint, pairingCode: code, deviceName: UIDevice.current.name)
        updateNowPlaying(macName: mac.name)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func disconnect() {
        diag("disconnect requested")
        pauseTask?.cancel()
        interruptionTask?.cancel()
        pausedByInterruption = false
        paused = false
        receiver.disconnect()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        configureAudioSession()
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
        if case .reconnecting = st { scheduleAddressFallback() } else { fallbackTask?.cancel() }
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

    /// Still reconnecting after 5 s: the address may be unreachable from this network (LAN address
    /// while away, or Tailscale switched off). Try the other one.
    private func scheduleAddressFallback() {
        guard fallbackTask == nil || fallbackTask!.isCancelled, let alt = connectedAlternate,
              let id = connectedID, var mac = allMacs.first(where: { $0.id == id }) else { return }
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, case .reconnecting = self.state else { return }
            let current = self.connectedHost
            diag("no audio via \(current ?? "?") for 5 s; trying \(alt)")
            mac.preferredHost = alt
            mac.alternateHost = current
            guard let code = Keychain.pairingCode(for: mac.pairingKey) ?? Self.debugPairingCode() else { return }
            self.connect(mac, code: code)
        }
    }

    // MARK: - Discovery

    private func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Constants.serviceType, domain: nil), using: params)
        b.stateUpdateHandler = { st in log.info("browser: \(String(describing: st), privacy: .public)") }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var byName: [String: MacEntry] = [:]
            for r in results {
                guard case .service(let name, _, _, _) = r.endpoint else { continue }
                var addr: String?, port: UInt16?, ts: String?
                if case .bonjour(let txt) = r.metadata {
                    addr = txt["addr"].flatMap { $0.isEmpty ? nil : $0 }
                    port = txt["port"].flatMap(UInt16.init)
                    ts = txt["ts"].flatMap { $0.isEmpty ? nil : $0 }
                }
                // The same Mac shows up once per interface; keep whichever result carries an address.
                if byName[name]?.preferredHost == nil {
                    var e = MacEntry.bonjour(name: name, preferredHost: addr, port: port, tailscaleHost: ts)
                    e.alternateHost = ts
                    byName[name] = e
                }
            }
            let entries = byName.values.sorted { $0.name < $1.name }
            Task { @MainActor in self?.updateDiscovered(entries) }
        }
        b.start(queue: .global(qos: .utility))
        browser = b
    }

    private func updateDiscovered(_ entries: [MacEntry]) {
        for e in entries where e.preferredHost != discovered.first(where: { $0.id == e.id })?.preferredHost {
            diag("discovered \(e.name) at \(e.preferredHost ?? "(no address advertised)")")
        }
        discovered = entries
        var known = knownAddresses
        for e in entries { if let h = e.preferredHost { known[e.id] = "\(h):\(e.port)" } }
        if known != knownAddresses {
            knownAddresses = known
            defaults.set(known, forKey: Key.knownAddresses)
        }
        var knownTS = knownTailscale
        for e in entries { if let ts = e.tailscaleHost { knownTS[e.id] = ts } }
        if knownTS != knownTailscale {
            knownTailscale = knownTS
            defaults.set(knownTS, forKey: Key.knownTailscale)
        }
        // Left the network the Mac is on while listening (e.g. walked out of Wi-Fi range): switch
        // to its Tailscale address instead of retrying a LAN address that's out of reach.
        if isActive, let id = connectedID, !entries.contains(where: { $0.id == id }),
           let away = rememberedAway.first(where: { $0.id == id }), away.viaTailscale,
           connectedHost != away.preferredHost {
            diag("\(away.name) left the local network; switching to Tailscale (\(away.preferredHost ?? "?"))")
            connect(away)
        }
        if selected == nil { selected = discovered.first ?? rememberedAway.first ?? manual.first }
        // Connected to a remembered address that the Mac no longer advertises (e.g. its DHCP
        // address changed): move to the current one.
        if isActive, let host = connectedHost, let current = entries.first(where: { $0.id == connectedID }),
           let fresh = current.preferredHost, fresh != host {
            diag("\(current.name) moved \(host) → \(fresh); reconnecting")
            connect(current)
        }
        if let pending = autoConnectPending, let m = discovered.first(where: { $0.id == pending }) {
            autoConnectPending = nil
            connect(m)
        }
    }

    // MARK: - Audio session

    /// `mixable` while the headphones are away: iOS lets a backgrounded app reactivate a mixable
    /// session (not an exclusive one), and playing (silence) keeps the app running, so the Mac
    /// subscription and "keep headphones" hold survive until they come back.
    private func configureAudioSession(mixable: Bool = false) {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: mixable ? [.mixWithOthers] : [])
            try s.setPreferredSampleRate(Constants.sampleRate)
            try s.setPreferredIOBufferDuration(0.005)
        } catch {
            log.error("audio session config: \(error)")
        }
    }

    @discardableResult
    private func activateAudioSession() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            diag("session activate failed: \(error.localizedDescription)")
            return false
        }
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
            let reason = (n.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
            diag("interruption began (reason \(reason.map { String($0.rawValue) } ?? "none"))")
            playback.muted = true
            // Headphones taken by another device (e.g. the Mac): without audio running iOS
            // suspends us, the Mac drops the subscription and nothing brings them back.
            if isActive, paused || reason == .routeDisconnected {
                if !paused { pauseForMissingHeadphones() }
                keepAliveWhileHeadphonesAway()
            } else if isActive {
                // Anything else (CarPlay ending, Siri, another app). iOS may never send "ended"
                // (wireless CarPlay disconnecting didn't), and with the engine stopped we'd be
                // suspended as soon as we're in the background. Unless it turns out to be a call
                // (handled by the call watcher), pause and stay alive.
                interruptionTask?.cancel()
                interruptionTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled, self.isActive, !self.calls.inCall, !self.paused else { return }
                    self.pausedByInterruption = true
                    self.pause(reason: "interrupted", grace: 600, recoverFromInterruption: true)
                    self.keepAlive(reason: "interrupted")
                }
            }
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(rawValue: n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            diag("interruption ended (resume=\(opts.contains(.shouldResume)))")
            interruptionTask?.cancel()
            if pausedByInterruption, isActive, !calls.inCall {
                if opts.contains(.shouldResume) { resume() }
            } else if calls.inCall, isActive {
                // iOS says "resume" several times during one call; playing then puts the Mac's
                // audio over the call. Stay silent but alive (mixable, muted) until it ends.
                keepAlive(reason: "call in progress")
            } else if opts.contains(.shouldResume), isActive {
                rebuildEngine(reason: "interruption ended")
            }
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
            pauseForMissingHeadphones()
        case .newDeviceAvailable:
            if paused { resume() } else if isActive, !playback.engine.isRunning { rebuildEngine(reason: "new device, engine stopped") }
        default:
            // Any other route change that stopped the engine (e.g. category/override changes).
            if isActive, !paused, !playback.engine.isRunning { rebuildEngine(reason: "route change \(reason.rawValue)") }
        }
    }

    /// Bluetooth proximity runs only in Auto mode while connected to a Mac.
    private func updateProximity() {
        let want = latencyMode == .auto && stats.state.isActive && !stats.macName.isEmpty
        if want {
            if !proximityRunning {
                proximityRunning = true
                proximity.onChange = { [weak self] near in self?.receiver.phoneNearMac = near }
            }
            proximity.start(macName: stats.macName)
            proximity.calibrating = stats.macInputRecent == true
        } else if proximityRunning {
            proximityRunning = false
            proximity.stop()
            receiver.phoneNearMac = nil
        }
    }

    private func pauseForMissingHeadphones() {
        // Long grace: the Mac stops capturing (and unmutes) while we're paused, so staying
        // subscribed costs little, and putting the AirPods back in resumes instantly.
        pause(reason: "output device went away", grace: 1800)
    }

    /// `grace`: how long to stay subscribed before giving up. Headphones gone: 60 s. An
    /// interruption: 10 min, checking every 5 s whether anything else is still playing; once
    /// nothing is, take the audio back (iOS often never says the interruption ended, e.g.
    /// after a call or when CarPlay disconnects).
    private func pause(reason: String, grace: TimeInterval = 60, recoverFromInterruption: Bool = false) {
        diag("\(reason); pausing (subscription kept for \(Int(grace)) s)")
        paused = true
        receiver.listening = false
        playback.muted = true
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            let start = Date()
            while Date().timeIntervalSince(start) < grace {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.paused else { return }
                if recoverFromInterruption, self.pausedByInterruption, !self.calls.inCall,
                   !AVAudioSession.sharedInstance().isOtherAudioPlaying {
                    diag("interruption over (nothing else playing); resuming")
                    self.resume()
                    return
                }
            }
            guard !Task.isCancelled, let self, self.paused else { return }
            log.notice("paused for \(Int(grace)) s; disconnecting")
            diag("paused for \(Int(grace)) s; disconnecting")
            self.disconnect()
        }
    }

    private func keepAliveWhileHeadphonesAway() {
        keepAlive(reason: "headphones away")
    }

    /// Silent but running (mixable session, muted engine), so iOS doesn't suspend the app and the
    /// Mac keeps the subscription.
    private func keepAlive(reason: String) {
        diag("\(reason): keeping the app alive with a mixable session")
        playback.muted = true
        configureAudioSession(mixable: true)
        rebuildEngine(reason: "keep alive: \(reason)")
    }

    /// Opening the app while connected means "I want to hear it": revive audio that an
    /// interruption stopped (in the foreground an exclusive session is allowed again).
    private func cameToForeground() {
        guard isActive, !calls.inCall else { return }
        if pausedByInterruption {
            diag("foreground after an interruption; resuming")
            resume()
        } else if !paused, !playback.engine.isRunning {
            diag("foreground with audio stopped; restarting")
            configureAudioSession()
            rebuildEngine(reason: "foreground")
        }
    }

    private func callChanged(_ inCall: Bool) {
        diag(inCall ? "call started: Halltone stays silent" : "call ended")
        guard isActive else { return }
        if inCall {
            playback.muted = true
        } else if !paused {
            configureAudioSession()
            rebuildEngine(reason: "call ended")
        }
    }

    func resume() {
        pauseTask?.cancel()
        interruptionTask?.cancel()
        pausedByInterruption = false
        paused = false
        receiver.listening = true
        playback.muted = calls.inCall
        configureAudioSession()
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
                // A backgrounded app can't start an exclusive session, only a mixable one. While
                // paused (output gone: headphones, car, AirPlay) or in a call that's all we need
                // (silence that keeps us alive); otherwise fall back to it rather than fail six
                // times and get suspended, which drops the Mac and never recovers.
                let quiet = self.paused || self.calls.inCall
                if quiet { self.configureAudioSession(mixable: true) }
                if !self.activateAudioSession(), !quiet {
                    diag("exclusive session refused; using a mixable one")
                    self.configureAudioSession(mixable: true)
                    self.activateAudioSession()
                }
                do {
                    try self.playback.restart()
                    if !self.paused, !self.calls.inCall { self.playback.muted = false }
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
        c.playCommand.addTarget { [weak self] _ in self?.remote(.play) ?? .commandFailed }
        c.pauseCommand.addTarget { [weak self] _ in self?.remote(.pause) ?? .commandFailed }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.remote(.playPause) ?? .commandFailed }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.remote(.next) ?? .commandFailed }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.remote(.previous) ?? .commandFailed }
    }

    private func remote(_ cmd: ControlCommand) -> MPRemoteCommandHandlerStatus {
        guard isActive else { return .noActionableNowPlayingItem }
        diag("remote command: \(cmd)")
        // Pause never brings Halltone back: iOS sends it when AirPods come out, and resuming then
        // played through the phone's speaker.
        if paused, cmd != .pause { resume() }
        // An older Mac only knows the toggle.
        let sent: ControlCommand = (cmd == .pause || cmd == .play) && !stats.macExplicitPlayPause ? .playPause : cmd
        receiver.sendControl(sent)
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
            MPNowPlayingInfoPropertyPlaybackRate: stats.macPlaying ? 1.0 : 0.0,
        ]
        nowPlayingRate = stats.macPlaying
    }

    /// Mirror whether the Mac is playing on the lock screen: iOS picks play vs pause for a
    /// headphone press from it, and explicit pause/play only act when they'd change something.
    private var nowPlayingRate = true
    private func syncNowPlayingRate() {
        guard stats.state.isActive, stats.macPlaying != nowPlayingRate, !stats.macName.isEmpty else { return }
        updateNowPlaying(macName: stats.macName)
    }
}
