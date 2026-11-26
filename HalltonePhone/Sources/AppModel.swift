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

    /// 25 MB; `-logShipBytes N` as a launch argument lowers it for testing.
    private static let shipBytes: Int = {
        let override = UserDefaults.standard.integer(forKey: "logShipBytes")
        return override > 0 ? override : 25_000_000
    }()

    private init() {
        url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("halltone.log")
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    func append(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { [url] in
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > Self.shipBytes {
                // Full: hand it to the Mac (LogShipper) and start a new one.
                LogShipper.shared.enqueue(url)
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

/// What the UI shows for one source being listened to.
struct SourceStatus: Identifiable {
    let id: String
    let name: String
    var stats: Receiver.Stats
    var config: SourceConfig
    /// What it plays in: the user's pick, else Auto, or Game for a sender using 2.5 ms frames.
    var effectiveMode: LatencyMode
    /// The lock screen and headphone buttons talk to this one.
    var isMediaSource: Bool
    var state: Receiver.State { stats.state }
}

/// Per-source bookkeeping that used to be single properties of the model: where it was reached,
/// the address fallback, Bluetooth proximity (per Mac), and the stats log throttle.
private final class SourceRuntime {
    var mac: MacEntry
    var code: UInt32
    var host: String?
    /// Where full diagnostics logs go (this Mac), and the code it accepts them with.
    var logHost: String?
    /// The other address (LAN or Tailscale) to try if this one stops getting through.
    var alternate: String?
    var fallbackTask: Task<Void, Never>?
    /// Bluetooth signal strength to this Mac, for Auto latency.
    let proximity = MacProximity()
    var proximityRunning = false
    var statsCounter = 0
    var lastLoggedUnderruns: UInt64 = 0

    init(mac: MacEntry, code: UInt32) { self.mac = mac; self.code = code }
}

@MainActor
final class AppModel: ObservableObject {
    private enum Key {
        static let manual = "manualMacs"
        static let autoConnect = "autoConnect"
        static let lastMac = "lastMac"
        /// Before several sources: one global latency mode. Seeds the per-source setting once.
        static let legacyLatencyMode = "latencyMode"
        static let keepHeadphones = "keepHeadphones"
        /// [Mac id: "host:port"]: last advertised address of each Bonjour Mac.
        static let knownAddresses = "knownAddresses"
        /// [Mac id: Tailscale IPv4]: from the TXT record, for reaching the Mac away from home.
        static let knownTailscale = "knownTailscale"
    }

    @Published private(set) var discovered: [MacEntry] = []
    @Published private(set) var manual: [MacEntry] = []
    @Published private(set) var selected: MacEntry?
    /// The sources being listened to, in the order they were turned on.
    @Published private(set) var sources: [SourceStatus] = []
    @Published private(set) var paused = false {
        didSet { updateIdleTimer() }
    }
    /// What the audio session says the output adds after our render callback (hardware and
    /// output buffer, ms), refreshed with the stats. Bluetooth shows up here as 150+ ms.
    @Published private(set) var outputLatencyMs = 0
    @Published var autoConnect: Bool { didSet { defaults.set(autoConnect, forKey: Key.autoConnect) } }
    /// Ask the Mac not to take the headphones back while this phone listens (and to resume
    /// playback if moving them paused it).
    @Published var keepHeadphones: Bool {
        didSet {
            defaults.set(keepHeadphones, forKey: Key.keepHeadphones)
            manager.holdHeadphones = keepHeadphones
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
    /// At least one source is connecting, connected or reconnecting.
    var isActive: Bool { manager.isActive }

    let playback = PlaybackEngine()
    private let manager: SourceManager
    private var runtimes: [String: SourceRuntime] = [:]
    private let defaults = UserDefaults.standard
    private var browser: NWBrowser?
    private var pauseTask: Task<Void, Never>?
    private let calls = CallWatcher()
    /// Other Halltone Macs nearby (not the one we listen to) are asked to guard the headphones
    /// too: macOS automatic switching lets any of the user's Macs take the AirPods when it plays.
    private var otherMacHoldTimer: Timer?
    private var otherMacConnections: [String: NWConnection] = [:]
    private var lastWantedGameBuffer = false
    private var interruptionTask: Task<Void, Never>?
    /// Paused by an audio interruption that may never end (not a call, not a lost output):
    /// opening the app resumes it.
    private var pausedByInterruption = false
    private var rebuildTask: Task<Void, Never>?
    /// Sources that were on at the last launch and haven't shown up on the network yet.
    private var autoConnectPending: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    init() {
        manager = SourceManager(bus: playback.bus, store: DefaultsSettingsStore(defaults))
        autoConnect = defaults.object(forKey: Key.autoConnect) as? Bool ?? true
        knownAddresses = defaults.dictionary(forKey: Key.knownAddresses) as? [String: String] ?? [:]
        knownTailscale = defaults.dictionary(forKey: Key.knownTailscale) as? [String: String] ?? [:]
        keepHeadphones = defaults.object(forKey: Key.keepHeadphones) as? Bool ?? true
        manager.holdHeadphones = keepHeadphones
        manager.deviceID = UIDevice.current.identifierForVendor?.uuidString
        if let data = defaults.data(forKey: Key.manual), let list = try? JSONDecoder().decode([MacEntry].self, from: data) {
            manual = list
        }
        migrateSingleSourceSettings()
        manager.onState = { [weak self] source, st in MainActor.assumeIsolated { self?.handleState(source, st) } }
        manager.onMacStatus = { [weak self] _, flags in
            guard flags.contains(.lastControlFailed) else { return }
            MainActor.assumeIsolated { self?.controlFailed() }
        }
        manager.onStats = { [weak self] source, s in MainActor.assumeIsolated { self?.handleStats(source, s) } }
        diag("launch (build \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
        configureAudioSession()
        observeAudioSession()
        installLifecycleObservers()
        setupRemoteCommands()
        otherMacHoldTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdOnOtherMacs() }
        }
        calls.onChange = { [weak self] inCall in self?.callChanged(inCall) }
        startBrowsing()
        if autoConnect {
            for id in manager.settings.enabled {
                if let m = manual.first(where: { $0.id == id }) {
                    connect(m)
                } else if let m = rememberedAway.first(where: { $0.id == id }) {
                    // Known address: connect right away (works at home and over a VPN); no need to
                    // wait for Bonjour, which doesn't cross VPNs.
                    connect(m)
                } else {
                    autoConnectPending.insert(id)
                }
            }
        }
    }

    private func handleStats(_ source: Source, _ s: Receiver.Stats) {
        refreshSources()
        refreshOutputLatency()
        updateProximity(for: source)
        syncNowPlayingRate()
        guard let rt = runtimes[source.id], s.state.isActive, shouldLogStats(s, rt) else { return }
        let rssi = rt.proximity.rssi.map { String(Int($0)) } ?? "-"
        var line = "stats atMac=\(s.atMac) near=\(s.phoneNearMac.map(String.init) ?? "-") rssi=\(rssi) active=\(s.macUserActive.map(String.init) ?? "-") input=\(s.macInputRecent.map(String.init) ?? "-") buf=\(s.bufferMs)/\(s.targetMs) loss=\(s.lossPercent)% pps=\(s.packetsPerSecond) under=\(s.underruns) cb=\(s.callbackFrames) gap=\(s.arrivalGapMs) maxgap10s=\(s.maxArrivalGapMs10s) timergap10s=\(s.maxTimerGapMs10s) bg=\(UIApplication.shared.applicationState == .background) primed=\(s.jitterPrimed) resets=\(s.jitterResets) queued=\(s.queuedMs) handoff=\(s.handoffMs) muted=\(playback.muted) concealed=\(s.concealedFrames) late=\(s.lateFrames) trimmed=\(s.trimmedFrames) stretched=\(s.stretchedFrames) wg=\(s.workgroupStatus.map(String.init) ?? "-") resendAsked=\(s.resendRequested) recovered=\(s.resendRecovered) engine=\(playback.engine.isRunning)"
        // Only when set: with one source at its defaults the line is what it always was.
        if source.config.volume != 1 { line += " vol=\(String(format: "%.2f", source.config.volume))" }
        if source.config.muted { line += " srcmuted=true" }
        sdiag(source, line)
    }

    private func installLifecycleObservers() {
        let nc = NotificationCenter.default
        for (name, label) in [(UIApplication.didEnterBackgroundNotification, "background"),
                              (UIApplication.willEnterForegroundNotification, "foreground"),
                              (UIApplication.didBecomeActiveNotification, "active"),
                              (UIApplication.willResignActiveNotification, "inactive"),
                              (UIApplication.willTerminateNotification, "terminate"),
                              (UIApplication.protectedDataWillBecomeUnavailableNotification, "locked"),
                              (UIApplication.protectedDataDidBecomeAvailableNotification, "unlocked")] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                diag("app \(label)")
                MainActor.assumeIsolated {
                    self?.updateIdleTimer()
                    if label == "locked" { self?.manager.screenLocked = true }
                    if label == "unlocked" { self?.manager.screenLocked = false }
                    if label == "locked" || label == "unlocked", self?.isActive == true {
                        // How fast the output pulled audio around the lock (12000 per entry = real time).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                for s in self.manager.sources {
                                    self.sdiag(s, "render per 250 ms around \(label): \(s.receiver.renderHistory())")
                                }
                            }
                        }
                    }
                }
                if label == "foreground" { Task { @MainActor in self?.cameToForeground() } }
            })
        }
    }

    /// First launch of the several-sources version: the one Mac and the one global latency mode
    /// from before become that Mac's entry in the set and its latency.
    private func migrateSingleSourceSettings() {
        guard manager.settings.isEmpty, let last = defaults.string(forKey: Key.lastMac) else { return }
        manager.settings.enable(last)
        if let old = defaults.string(forKey: Key.legacyLatencyMode).flatMap(LatencyMode.init(rawValue:)), old != .auto {
            manager.settings.update(last) { $0.latency = old }
        }
    }

    // MARK: - Connect / disconnect

    /// Turn a source on: connect to it, alongside any others already playing.
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
    /// Every 10 s while healthy; every second while packets are short or playback underruns, so
    /// trouble is logged in detail but the file still covers hours (at 1/s it covered ~40 min).
    private func shouldLogStats(_ s: Receiver.Stats, _ rt: SourceRuntime) -> Bool {
        rt.statsCounter += 1
        let subscribed = if case .subscribed = s.state { true } else { false }
        let troubled = !subscribed || (!paused && (s.underruns != rt.lastLoggedUnderruns || s.packetsPerSecond < 90))
        rt.lastLoggedUnderruns = s.underruns
        return troubled || rt.statsCounter % 10 == 1
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

    /// Set once a second source joins, until the next session starts from none.
    private var namedLogging = false

    /// A diagnostics line about one source. Once several sources are in play it starts with the
    /// source's name (with one source, lines are what they always were).
    private func sdiag(_ source: Source, _ message: String) {
        diag(namedLogging ? "[\(source.name)] \(message)" : message)
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

    /// The pairing prompt was cancelled: a source waiting for its code isn't left half on.
    func cancelPairing() {
        if let mac = pairingPrompt, let s = manager.source(id: mac.id), !s.isActive { turnOff(mac.id) }
        pairingPrompt = nil
    }

    private func connect(_ mac: MacEntry, code: UInt32) {
        guard !manager.isFull || manager.source(id: mac.id) != nil else {
            errorText = "Halltone can play up to \(MixBus.maxChannels) sources at once. Turn one off first."
            return
        }
        let rt = runtimes[mac.id] ?? SourceRuntime(mac: mac, code: code)
        runtimes[mac.id] = rt
        rt.mac = mac
        rt.code = code
        rt.logHost = mac.preferredHost ?? (mac.kind == .manual ? mac.host : nil)
        rt.host = mac.preferredHost
        rt.alternate = mac.alternateHost
        rt.fallbackTask?.cancel()
        // The first source (nothing else playing) starts from a clean slate, as connecting always did.
        let others = manager.sources.contains { $0.id != mac.id && $0.isActive }
        if manager.sources.isEmpty { namedLogging = false }
        if manager.sources.contains(where: { $0.id != mac.id }) { namedLogging = true }
        let via = mac.preferredHost ?? (mac.kind == .manual ? mac.host : "Bonjour")
        diag(namedLogging ? "[\(mac.name)] connect → \(mac.name) via \(via)" : "connect → \(mac.name) via \(via)")
        selected = mac
        defaults.set(mac.id, forKey: Key.lastMac)
        autoConnectPending.remove(mac.id)
        if !others {
            paused = false
            manager.listening = true
            pauseTask?.cancel()
            interruptionTask?.cancel()
            pausedByInterruption = false
            // A previous session may have ended muted (headphones away, interruption); a muted
            // engine never reads the hand-off rings, so the new stream would never start playing.
            playback.muted = calls.inCall
        }
        configureAudioSession()
        lastWantedGameBuffer = wantsGameBuffer
        activateAudioSession()
        manager.connect(id: mac.id, name: mac.name, endpoint: mac.endpoint, pairingCode: code,
                        deviceName: UIDevice.current.name)
        refreshSources()
        updateNowPlaying()
        updateIdleTimer()
    }

    /// The Disconnect button: every source stops. The set that comes back at launch is kept.
    func disconnect() {
        diag("disconnect requested")
        allowSharedOutput = false
        pauseTask?.cancel()
        interruptionTask?.cancel()
        pausedByInterruption = false
        paused = false
        for rt in runtimes.values { rt.fallbackTask?.cancel() }
        manager.disconnectAll()
        endSession()
    }

    /// A source's switch turned off: stop it and don't bring it back at launch.
    func turnOff(_ id: String) {
        guard let s = manager.source(id: id) else { manager.settings.disable(id); return }
        sdiag(s, "turned off")
        runtimes[id]?.fallbackTask?.cancel()
        stopProximity(for: id)
        manager.disconnect(id: id)
        refreshSources()
        if !manager.isActive { disconnectedLast() } else { updateNowPlaying(); updateLogTarget() }
    }

    /// Whether a source's switch shows on: connecting or connected, or waiting for its pairing code.
    func isOn(_ id: String) -> Bool {
        manager.source(id: id)?.isActive == true || pairingPrompt?.id == id
    }

    /// The last source went away through its own switch: same wrap-up as Disconnect.
    private func disconnectedLast() {
        allowSharedOutput = false
        pauseTask?.cancel()
        interruptionTask?.cancel()
        pausedByInterruption = false
        paused = false
        endSession()
    }

    private func endSession() {
        refreshSources()
        updateLogTarget()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        configureAudioSession()
    }

    /// The Connect button: bring back the sources that were on, or else the selected (or first) one.
    func toggle() {
        if isActive { disconnect(); return }
        let known = allMacs
        let wanted = manager.settings.enabled.compactMap { id in known.first { $0.id == id } }
        if !wanted.isEmpty { wanted.forEach { connect($0) } }
        else if let s = selected ?? known.first { connect(s) }
    }

    /// Whether the Connect button has something to connect.
    var canConnect: Bool { selected != nil || !allMacs.isEmpty }

    func select(_ mac: MacEntry) { selected = mac }

    func addManual(host: String, port: UInt16) {
        let entry = MacEntry.manual(host: host.trimmingCharacters(in: .whitespaces), port: port)
        guard !manual.contains(entry) else { return }
        manual.append(entry)
        persistManual()
        selected = entry
    }

    func removeManual(_ entry: MacEntry) {
        if manager.source(id: entry.id) != nil { turnOff(entry.id) }
        manager.settings.forget(entry.id)
        manual.removeAll { $0.id == entry.id }
        persistManual()
        if selected == entry { selected = nil }
    }

    func forgetPairing(_ mac: MacEntry) { Keychain.delete(for: mac.pairingKey) }

    private func persistManual() {
        if let data = try? JSONEncoder().encode(manual) { defaults.set(data, forKey: Key.manual) }
    }

    // MARK: - Per-source controls

    func setVolume(_ volume: Float, for id: String) {
        manager.setVolume(volume, for: id)
        refreshSources()
    }

    func setMuted(_ muted: Bool, for id: String) {
        manager.setMuted(muted, for: id)
        if let s = manager.source(id: id) { sdiag(s, muted ? "muted" : "unmuted") }
        refreshSources()
    }

    /// nil = the default for the sender (Auto, or Game for 2.5 ms frames).
    func setLatency(_ mode: LatencyMode?, for id: String) {
        manager.setLatency(mode, for: id)
        if let s = manager.source(id: id) {
            sdiag(s, "latency mode: \(mode?.rawValue ?? "default (\(s.effectiveMode.rawValue))")")
            updateProximity(for: s)
        }
        refreshSources()
    }

    /// The config of a source whether or not it's connected.
    func config(for id: String) -> SourceConfig { manager.settings.config(for: id) }

    private func refreshSources() {
        let media = manager.mediaSource?.id
        sources = manager.sources.map {
            SourceStatus(id: $0.id, name: $0.name, stats: $0.stats, config: $0.config,
                         effectiveMode: $0.effectiveMode, isMediaSource: $0.id == media)
        }
        updateIdleTimer()
        let wantsGame = wantsGameBuffer
        if wantsGame != lastWantedGameBuffer {
            lastWantedGameBuffer = wantsGame
            applyIOBufferPreference()
        }
    }

    private func handleState(_ source: Source, _ st: Receiver.State) {
        sdiag(source, "state: \(st)")
        let current = manager.source(id: source.id) === source
        refreshSources()
        let rt = runtimes[source.id]
        if case .reconnecting = st { if current { scheduleAddressFallback(source) } } else { rt?.fallbackTask?.cancel() }
        updateLogTarget()
        guard current else { return }
        switch st {
        case .rejected(let why):
            if let mac = rt?.mac {
                Keychain.delete(for: mac.pairingKey)
                pairingError = why
                pairingInput = ""
                pairingPrompt = mac
            }
        case .failed(let why):
            errorText = "\(manager.sources.count > 1 ? "\(source.name): " : "")\(why)"
        case .subscribed:
            updateNowPlaying()
        default: break
        }
        if st == .idle || !st.isActive { stopProximity(for: source.id, ifNotConnected: true) }
    }

    /// Diagnostics logs go to the Mac we're subscribed to (the media source if there are several).
    private func updateLogTarget() {
        let ready = manager.sources.filter { if case .subscribed = $0.state { return true } else { return false } }
        guard let s = (manager.mediaSource.flatMap { m in ready.first { $0 === m } } ?? ready.first),
              let rt = runtimes[s.id], let host = rt.host ?? rt.logHost else {
            LogShipper.shared.target = nil
            return
        }
        LogShipper.shared.target = .init(host: host, pairingCode: rt.code, deviceName: UIDevice.current.name)
    }

    /// Still reconnecting after 5 s: the address may be unreachable from this network (LAN address
    /// while away, or Tailscale switched off). Try the other one.
    private func scheduleAddressFallback(_ source: Source) {
        guard let rt = runtimes[source.id], rt.fallbackTask == nil || rt.fallbackTask!.isCancelled,
              let alt = rt.alternate, var mac = allMacs.first(where: { $0.id == source.id }) else { return }
        rt.fallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, case .reconnecting = source.state,
                  manager.source(id: source.id) === source else { return }
            let current = rt.host
            sdiag(source, "no audio via \(current ?? "?") for 5 s; trying \(alt)")
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
        for source in manager.sources where source.isActive {
            guard let rt = runtimes[source.id] else { continue }
            if !entries.contains(where: { $0.id == source.id }),
               let away = rememberedAway.first(where: { $0.id == source.id }), away.viaTailscale,
               rt.host != away.preferredHost {
                sdiag(source, "\(away.name) left the local network; switching to Tailscale (\(away.preferredHost ?? "?"))")
                connect(away)
            }
        }
        if selected == nil { selected = discovered.first ?? rememberedAway.first ?? manual.first }
        // Connected to a remembered address that the Mac no longer advertises (e.g. its DHCP
        // address changed): move to the current one.
        for source in manager.sources where source.isActive {
            if let rt = runtimes[source.id], let host = rt.host, let current = entries.first(where: { $0.id == source.id }),
               let fresh = current.preferredHost, fresh != host {
                sdiag(source, "\(current.name) moved \(host) → \(fresh); reconnecting")
                connect(current)
            }
        }
        for pending in autoConnectPending {
            if let m = discovered.first(where: { $0.id == pending }) { connect(m) }
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
            try s.setPreferredIOBufferDuration(preferredIOBufferDuration)
        } catch {
            log.error("audio session config: \(error)")
        }
    }

    /// 5 ms normally; 2.5 ms (128 frames at 48 kHz) in Game mode. iOS decides what it grants
    /// (the route matters: Bluetooth ignores it); `logGrantedIOBuffer` records the result.
    private var preferredIOBufferDuration: TimeInterval { wantsGameBuffer ? 0.0025 : 0.005 }

    /// Any source plays in Game mode (by its frames, or because it was set to Game).
    private var wantsGameBuffer: Bool {
        manager.sources.contains { $0.effectiveMode == .game }
            || manager.settings.enabled.contains { manager.settings.config(for: $0).latency == .game }
    }

    private func logGrantedIOBuffer(_ why: String) {
        let s = AVAudioSession.sharedInstance()
        diag("IO buffer (\(why)): asked \(String(format: "%.2f", preferredIOBufferDuration * 1000)) ms, granted \(String(format: "%.2f", s.ioBufferDuration * 1000)) ms, output latency \(String(format: "%.1f", s.outputLatency * 1000)) ms, route \(s.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))")
    }

    /// Entering or leaving Game mode while connected: ask the session again and log what comes
    /// back (it can take a moment to apply).
    private func applyIOBufferPreference() {
        guard isActive else { return }
        do { try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(preferredIOBufferDuration) }
        catch { diag("IO buffer request failed: \(error.localizedDescription)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.logGrantedIOBuffer("mode change") }
        }
    }

    private func refreshOutputLatency() {
        let s = AVAudioSession.sharedInstance()
        let ms = Int(((s.outputLatency + s.ioBufferDuration) * 1000).rounded())
        if ms != outputLatencyMs { outputLatencyMs = ms }
    }

    /// Game mode keeps the screen on while the app is in front and playing: locking the phone
    /// makes iOS deepen its output buffer (100+ ms), which is the delay Game mode removes.
    private func updateIdleTimer() {
        let keepAwake = manager.sources.contains { $0.isActive && $0.effectiveMode == .game } && !paused
            && UIApplication.shared.applicationState == .active
        if UIApplication.shared.isIdleTimerDisabled != keepAwake {
            UIApplication.shared.isIdleTimerDisabled = keepAwake
            diag("screen kept awake: \(keepAwake)")
        }
    }

    @discardableResult
    private func activateAudioSession() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            logGrantedIOBuffer("activated")
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
            Task { @MainActor in
                guard let self else { return }
                // iOS's audio server restarted: every session setting and engine is gone, even
                // while we're idle (connecting later on the dead engine failed with -50).
                diag("media services reset")
                self.configureAudioSession()
                if self.isActive { self.rebuildEngine(reason: "media services reset") } else { self.playback.discardEngine() }
            }
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
        guard isActive else { return }
        if reason == .oldDeviceUnavailable {
            pauseForMissingHeadphones()
            return
        }
        // Halltone only plays into personal audio. CarPlay (which runs over AirPlay), AirPlay
        // and speakers are shared: when the output moves there, pause and stay quiet instead of
        // taking over the car or the TV.
        guard Self.outputIsPersonal else {
            sharedOutputAt = Date()
            if !paused, !allowSharedOutput {
                pause(reason: "output moved to \(outputs), not headphones", grace: 1800)
                keepAlive(reason: "not headphones")
            }
            return
        }
        allowSharedOutput = false
        if paused, reason == .newDeviceAvailable {
            resume()
        } else if !paused, !playback.engine.isRunning {
            // Any other route change that stopped the engine (e.g. category/override changes).
            rebuildEngine(reason: "route change \(reason.rawValue)")
        }
    }

    /// Headphones of some kind: AirPods/Bluetooth, wired, USB. Not CarPlay, AirPlay or speakers.
    private static var outputIsPersonal: Bool {
        #if DEBUG
        if DebugSettings.allowSpeakerOutput { return true } // latency tests: the phone's speaker counts
        #endif
        let personal: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones, .usbAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { personal.contains($0.portType) }
    }

    /// When the output last moved to CarPlay/AirPlay/speaker. A car sends "play" to the last
    /// app as CarPlay connects; that mustn't start the Mac.
    private var sharedOutputAt = Date.distantPast
    /// The user tapped Resume while on CarPlay/AirPlay/speaker: play there until the output
    /// changes to something else (or they disconnect).
    private var allowSharedOutput = false

    /// The Resume button: an explicit request, so it may play into the car or a speaker.
    func userResume() {
        allowSharedOutput = !Self.outputIsPersonal
        resume()
    }

    /// Bluetooth proximity runs per source, only while it plays in Auto mode and is connected.
    private func updateProximity(for source: Source) {
        guard let rt = runtimes[source.id] else { return }
        let stats = source.stats
        let live = manager.source(id: source.id) === source
        let want = live && source.effectiveMode == .auto && stats.state.isActive && !stats.macName.isEmpty
        if want {
            if !rt.proximityRunning {
                rt.proximityRunning = true
                rt.proximity.onChange = { [weak source] near in source?.receiver.phoneNearMac = near }
                let name = source.name
                rt.proximity.prefix = { [weak self] in
                    MainActor.assumeIsolated { self?.namedLogging == true ? "[\(name)] " : "" }
                }
            }
            rt.proximity.start(macName: stats.macName)
            rt.proximity.calibrating = stats.macInputRecent == true
        } else if rt.proximityRunning {
            rt.proximityRunning = false
            rt.proximity.stop()
            source.receiver.phoneNearMac = nil
        }
    }

    private func stopProximity(for id: String, ifNotConnected: Bool = false) {
        guard let rt = runtimes[id], rt.proximityRunning else { return }
        if ifNotConnected, manager.source(id: id)?.isActive == true { return }
        rt.proximityRunning = false
        rt.proximity.stop()
        manager.source(id: id)?.receiver.phoneNearMac = nil
    }

    private func pauseForMissingHeadphones() {
        outputGoneAt = Date()
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
        manager.listening = false
        playback.muted = true
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            let start = Date()
            while Date().timeIntervalSince(start) < grace {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.paused else { return }
                if recoverFromInterruption, self.pausedByInterruption, !self.calls.inCall,
                   !AVAudioSession.sharedInstance().isOtherAudioPlaying, Self.outputIsPersonal {
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

    private func holdOnOtherMacs() {
        let want = keepHeadphones && isActive && !paused
        let others = discovered.filter { manager.source(id: $0.id) == nil && $0.preferredHost != nil }
        guard want, !others.isEmpty else {
            for c in otherMacConnections.values { c.cancel() }
            otherMacConnections.removeAll()
            return
        }
        let packet = Packet(seq: 0, session: 0, message: .control(command: .holdHeadphonesOn)).encode()
        for mac in others {
            let key = "\(mac.preferredHost!):\(mac.port)"
            let c = otherMacConnections[key] ?? {
                let c = NWConnection(to: mac.endpoint, using: .udp)
                c.start(queue: .global(qos: .utility))
                otherMacConnections[key] = c
                diag("asking \(mac.name) to guard the headphones too")
                return c
            }()
            c.send(content: packet, completion: .idempotent)
        }
    }

    /// Opening the app while connected means "I want to hear it": revive audio that an
    /// interruption stopped (in the foreground an exclusive session is allowed again).
    private func cameToForeground() {
        guard isActive, !calls.inCall else { return }
        if pausedByInterruption, Self.outputIsPersonal {
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
        manager.listening = true
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
        // Play/pause/next/previous go to the media source: the one whose STATUS says controls work
        // (the one that most recently started playing if several do). The rest are never targeted.
        guard let target = manager.mediaSource else {
            diag("remote command: \(cmd): no source has working controls; ignoring")
            return .noActionableNowPlayingItem
        }
        diag(namedLogging ? "remote command: \(cmd) → \(target.name)" : "remote command: \(cmd)")
        if cmd != .pause, cmd != .next, cmd != .previous,
           Date().timeIntervalSince(sharedOutputAt) < 5 || (paused && !Self.outputIsPersonal) {
            // The car's automatic "play" as CarPlay connects (or any play while we're paused on
            // a shared output): don't start the Mac or take over the car. Open Halltone and tap
            // Resume to listen there on purpose.
            diag("ignoring \(cmd): output isn't headphones")
            return .commandFailed
        }
        // Pause never brings Halltone back: iOS sends it when AirPods come out, and resuming then
        // played through the phone's speaker.
        if paused, cmd != .pause { resume() }
        let stats = target.stats
        if cmd == .pause, stats.macExplicitPlayPause {
            // iOS sends "pause" for two different things. Halltone is always outputting audio
            // (silence while the video is paused), so iOS thinks it's playing and turns every
            // AirPods press into "pause", including the one meant to unpause. Taking the AirPods
            // out also sends "pause". While the Mac plays, both mean pause.
            if stats.macPlaying {
                pendingPress?.cancel(); pendingPress = nil
                target.receiver.sendControl(.pause)
                return .success
            }
            // Mac paused: a press means play, taking them out means nothing. Each earbud coming
            // out sends its own "pause" (seen 2 s apart) and the route only changes ~1.3 s after
            // the last, so wait for it; a second "pause" meanwhile is the other earbud.
            if pendingPress != nil {
                pendingPress?.cancel(); pendingPress = nil
                diag("second pause while paused: headphones coming out; ignoring")
                return .success
            }
            let at = Date()
            pendingPress = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                self.pendingPress = nil
                guard self.isActive else { return }
                let since = at.addingTimeInterval(-0.5)
                let removed = self.outputGoneAt >= since || self.sharedOutputAt >= since || !Self.outputIsPersonal
                diag(removed ? "pause with headphones removed: nothing to do" : "pause from a headphone press: play")
                if !removed { target.receiver.sendControl(.play) }
            }
            return .success
        }
        // An older Mac only knows the toggle.
        let sent: ControlCommand = (cmd == .pause || cmd == .play) && !stats.macExplicitPlayPause ? .playPause : cmd
        target.receiver.sendControl(sent)
        return .success
    }

    /// When headphones (or another personal output) last went away.
    private var outputGoneAt = Date.distantPast
    /// A "pause" that arrived while the Mac was paused, waiting to see whether it was a press.
    private var pendingPress: Task<Void, Never>?

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
            self.updateNowPlaying()
        }
    }

    func dismissControlsHelpBanner() { showControlsHelpBanner = false }

    /// Which Mac the "how to turn on headphone controls" help is about: one whose controls are off.
    var controlsHelpName: String {
        let s = sources.first { $0.stats.macControlsAvailable == false } ?? sources.first
        return s.map { $0.stats.macName.isEmpty ? $0.name : $0.stats.macName } ?? "your Mac"
    }

    /// What the lock screen shows: the media source (its name, and whether it is playing). With no
    /// media source, every connected source's name, playing if any of them is.
    private var nowPlayingState: (artist: String, playing: Bool)? {
        func name(_ s: Source) -> String { s.stats.macName.isEmpty ? s.name : s.stats.macName }
        let live = manager.sources.filter { $0.isActive }
        guard !live.isEmpty else { return nil }
        if let m = manager.mediaSource { return (name(m), m.stats.macPlaying) }
        return (live.map(name).joined(separator: ", "), live.contains { $0.stats.macPlaying })
    }

    private func updateNowPlaying() {
        guard let now = nowPlayingState else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Halltone",
            MPMediaItemPropertyArtist: now.artist,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: now.playing ? 1.0 : 0.0,
        ]
        nowPlayingShown = now
    }

    /// Mirror whether the media source is playing on the lock screen: iOS picks play vs pause for a
    /// headphone press from it, and explicit pause/play only act when they'd change something.
    private var nowPlayingShown: (artist: String, playing: Bool)?
    private func syncNowPlayingRate() {
        guard let now = nowPlayingState, !now.artist.isEmpty,
              now.playing != nowPlayingShown?.playing || now.artist != nowPlayingShown?.artist else { return }
        updateNowPlaying()
    }
}
