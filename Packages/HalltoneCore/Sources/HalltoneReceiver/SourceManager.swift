import Foundation
import Network
import os
import HalltoneCore

private let log = Logger(subsystem: Constants.logSubsystem, category: "Sources")

/// `UserDefaults` as a `SettingsStore`.
public final class DefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// One sender being listened to: its receiver (socket, jitter buffer, decode pump, stats,
/// reconnect state), its channel in the mix, and what the user set for it.
public final class Source {
    public let id: String
    public internal(set) var name: String
    public internal(set) var config: SourceConfig
    public let receiver: Receiver
    let channel: PlaybackChannel
    /// The latest stats the receiver published (which include its state).
    public internal(set) var stats = Receiver.Stats()
    /// When the sender's playing/paused status last changed (for choosing the media source).
    public internal(set) var playingChangedAt: TimeInterval = 0
    private var playingKnown = false

    init(id: String, name: String, config: SourceConfig, receiver: Receiver, channel: PlaybackChannel) {
        self.id = id; self.name = name; self.config = config
        self.receiver = receiver; self.channel = channel
    }

    public var state: Receiver.State { stats.state }
    /// Connecting, connected or reconnecting (not idle, rejected or failed).
    public var isActive: Bool { stats.state.isActive }
    /// What this source plays in: the user's pick, else Auto, or Game for 2.5 ms frames.
    public var effectiveMode: LatencyMode {
        LatencyMode.resolve(choice: config.latency, frameSamples: stats.frameSamples)
    }

    func notePlaying(_ playing: Bool, at now: TimeInterval) {
        guard !playingKnown || playing != stats.macPlaying else { return }
        playingKnown = true
        playingChangedAt = now
    }
}

/// Owns the sources the phone listens to at once: one `Receiver` and mix channel each, their
/// persisted settings (which are on, volume, mute, latency), the choice of media source, and the
/// settings that apply to all of them (listening/paused, screen lock, hold headphones).
///
/// Call it from one thread (the main thread in the app). Receiver callbacks are re-delivered on
/// `callbackQueue`.
public final class SourceManager {
    public let bus: MixBus
    public let settings: SourceSettings
    /// Connected, connecting or reconnecting sources, in the order they were added.
    public private(set) var sources: [Source] = []

    /// Called on `callbackQueue`. The source is passed even after `disconnect(id:)` removed it, so
    /// the final `.idle` can be seen.
    public var onState: ((Source, Receiver.State) -> Void)?
    public var onStats: ((Source, Receiver.Stats) -> Void)?
    public var onMacStatus: ((Source, StatusFlags) -> Void)?

    public var deviceID: String? { didSet { sources.forEach { $0.receiver.deviceID = deviceID } } }
    /// False while the app is paused (headphones out): applies to every source.
    public var listening = true { didSet { sources.forEach { $0.receiver.listening = listening } } }
    public var screenLocked = false { didSet { sources.forEach { $0.receiver.screenLocked = screenLocked } } }
    public var holdHeadphones = false { didSet { sources.forEach { $0.receiver.holdHeadphones = holdHeadphones } } }

    private let callbackQueue: DispatchQueue
    private let pairingStore: PairingStore?
    private let makeReceiver: (PlaybackSink) -> Receiver
    private let clock: () -> TimeInterval
    private var mediaChoice: String?

    public init(bus: MixBus, store: SettingsStore, callbackQueue: DispatchQueue = .main,
                pairingStore: PairingStore? = nil,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                makeReceiver: @escaping (PlaybackSink) -> Receiver = { Receiver(sink: $0) }) {
        self.bus = bus
        self.settings = SourceSettings(store: store)
        self.callbackQueue = callbackQueue
        self.pairingStore = pairingStore
        self.clock = clock
        self.makeReceiver = makeReceiver
    }

    public func source(id: String) -> Source? { sources.first { $0.id == id } }
    public var isActive: Bool { sources.contains { $0.isActive } }
    public var isFull: Bool { sources.count >= MixBus.maxChannels }

    // MARK: - Connect / disconnect

    /// Start listening to a sender (or point an already connected one at a new address) and
    /// remember it as on. Nil if every channel of the mix is taken.
    @discardableResult
    public func connect(id: String, name: String, endpoint: NWEndpoint, pairingCode: UInt32,
                        deviceName: String) -> Source? {
        settings.enable(id)
        if let existing = source(id: id) {
            existing.name = name
            existing.receiver.connect(to: endpoint, pairingCode: pairingCode, deviceName: deviceName)
            return existing
        }
        guard let channel = bus.claimChannel() else {
            log.error("no free mix channel for \(name, privacy: .public)")
            return nil
        }
        let receiver = makeReceiver(channel)
        let source = Source(id: id, name: name, config: settings.config(for: id), receiver: receiver, channel: channel)
        apply(source.config, to: source)
        receiver.deviceID = deviceID
        receiver.listening = listening
        receiver.screenLocked = screenLocked
        receiver.holdHeadphones = holdHeadphones
        wire(source)
        sources.append(source)
        receiver.connect(to: endpoint, pairingCode: pairingCode, deviceName: deviceName)
        return source
    }

    /// Stop listening to one source. `turnOff`: also forget that it was on (the usual per-row
    /// switch); false keeps it in the set that reconnects at launch (a timeout, the Disconnect button).
    public func disconnect(id: String, turnOff: Bool = true) {
        if turnOff { settings.disable(id) }
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        let source = sources.remove(at: i)
        if mediaChoice == id { mediaChoice = nil }
        let channel = source.channel, bus = self.bus
        // Hand the channel back only once the receiver has stopped writing to it.
        source.receiver.disconnect { bus.release(channel) }
    }

    /// Delete a source for good: disconnect it, forget its settings and its place in the set that
    /// reconnects at launch, and delete its stored pairing code so the next connection asks again.
    /// If it was the media source, the choice moves to the next eligible one.
    public func remove(id: String, pairingKey: String) {
        disconnect(id: id)
        settings.forget(id)
        pairingStore?.deletePairingCode(for: pairingKey)
        if mediaChoice == id { mediaChoice = nil }
    }

    /// Disconnect everything. The set that comes back at launch is left as it was.
    public func disconnectAll() {
        for s in sources { disconnect(id: s.id, turnOff: false) }
    }

    // MARK: - Per-source settings

    public func setVolume(_ volume: Float, for id: String) { update(id) { $0.volume = volume } }
    public func setMuted(_ muted: Bool, for id: String) { update(id) { $0.muted = muted } }
    /// nil = the default for the sender (Auto, or Game for 2.5 ms frames).
    public func setLatency(_ mode: LatencyMode?, for id: String) { update(id) { $0.latency = mode } }

    private func update(_ id: String, _ change: (inout SourceConfig) -> Void) {
        settings.update(id, change)
        guard let s = source(id: id) else { return }
        s.config = settings.config(for: id)
        apply(s.config, to: s)
    }

    private func apply(_ c: SourceConfig, to s: Source) {
        s.channel.volume = c.volume
        s.channel.muted = c.muted
        s.receiver.latencyMode = c.latency ?? .auto
        s.receiver.gameFramesPlayAsGame = c.latency == nil
    }

    // MARK: - Media source

    /// The source the lock screen and headphone buttons talk to: among sources whose STATUS says
    /// controls are available, the one that most recently started playing. Sources without controls
    /// are not targeted, except that with a single source the buttons still go to it (a Mac whose
    /// controls aren't set up still answers, and that is how the phone learns to explain it).
    public var mediaSource: Source? {
        let live = sources.filter { $0.isActive }
        let candidates = live.map {
            MediaSourceCandidate(id: $0.id, controlsAvailable: $0.stats.macControlsAvailable,
                                 playing: $0.stats.macPlaying, playingChangedAt: $0.playingChangedAt)
        }
        if let id = MediaSourceChooser.choose(candidates, current: mediaChoice) {
            mediaChoice = id
            return live.first { $0.id == id }
        }
        mediaChoice = nil
        return live.count == 1 ? live[0] : nil
    }

    // MARK: - Receiver callbacks

    private func wire(_ source: Source) {
        let q = callbackQueue
        source.receiver.onState = { [weak self] st in
            q.async { self?.handleState(source, st) }
        }
        source.receiver.onStats = { [weak self] s in
            q.async { self?.handleStats(source, s) }
        }
        source.receiver.onMacStatus = { [weak self] flags in
            q.async { self?.onMacStatus?(source, flags) }
        }
    }

    func handleState(_ source: Source, _ state: Receiver.State) {
        source.stats.state = state
        onState?(source, state)
    }

    func handleStats(_ source: Source, _ stats: Receiver.Stats) {
        if stats.state.isActive { source.notePlaying(stats.macPlaying, at: clock()) }
        source.stats = stats
        onStats?(source, stats)
    }
}
