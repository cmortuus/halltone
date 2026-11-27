import Foundation

// Pure logic behind listening to several senders at once: what's remembered about each source,
// and which one the lock screen / headphone buttons talk to. No sockets, no audio.

/// What the user chose for one source. Pairing codes are not here: they stay in the Keychain.
public struct SourceConfig: Codable, Equatable {
    /// 0...1 (the mixer applies its square).
    public var volume: Float = 1
    public var muted = false
    /// nil = the default: Auto, or Game for a sender using 2.5 ms frames.
    public var latency: LatencyMode?
    public init(volume: Float = 1, muted: Bool = false, latency: LatencyMode? = nil) {
        self.volume = volume; self.muted = muted; self.latency = latency
    }
}

extension LatencyMode {
    /// The mode a source plays in: an explicit pick wins; otherwise Auto, or Game when the sender
    /// uses 2.5 ms frames (its own Game mode: a game stream wants the game buffer).
    ///
    /// `slowOutput` (Bluetooth: over ~80 ms of output latency) makes the default Lowest instead of
    /// Game: a 15 ms buffer is pointless in front of 160 ms of headphones, and all risk.
    public static func resolve(choice: LatencyMode?, frameSamples: Int, slowOutput: Bool = false) -> LatencyMode {
        if let choice { return choice }
        guard frameSamples == Constants.pcmGameFrameSamples else { return .auto }
        return slowOutput ? .lowest : .game
    }
}

/// Where settings live: `UserDefaults` in the apps, a dictionary in tests.
public protocol SettingsStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public final class MemorySettingsStore: SettingsStore {
    private var values: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { values[key] }
    public func set(_ data: Data?, forKey key: String) { values[key] = data }
}

/// Where pairing codes live: the Keychain in the phone app, a dictionary in tests. Keyed by the
/// source's pairing key (a Bonjour name, or the id of a manual entry).
public protocol PairingStore: AnyObject {
    func deletePairingCode(for key: String)
}

public final class MemoryPairingStore: PairingStore {
    public private(set) var codes: [String: UInt32]
    public init(codes: [String: UInt32] = [:]) { self.codes = codes }
    public func deletePairingCode(for key: String) { codes[key] = nil }
}

/// The set of sources the user turned on (kept across launches, in the order they were added) and
/// each source's volume, mute and latency choice. Written through to the store on every change.
public final class SourceSettings {
    public static let key = "sourceSettings"
    private struct Stored: Codable { var enabled: [String]; var configs: [String: SourceConfig] }

    private let store: SettingsStore
    public private(set) var enabled: [String]
    public private(set) var configs: [String: SourceConfig]

    public init(store: SettingsStore) {
        self.store = store
        if let data = store.data(forKey: Self.key), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            enabled = s.enabled; configs = s.configs
        } else {
            enabled = []; configs = [:]
        }
    }

    /// A store that has never held settings (a first launch, or an upgrade from the one-source
    /// app): the caller seeds it from the old keys.
    public var isEmpty: Bool { store.data(forKey: Self.key) == nil }

    public func isEnabled(_ id: String) -> Bool { enabled.contains(id) }

    public func enable(_ id: String) {
        guard !enabled.contains(id) else { return }
        enabled.append(id)
        save()
    }

    public func disable(_ id: String) {
        guard enabled.contains(id) else { return }
        enabled.removeAll { $0 == id }
        save()
    }

    public func config(for id: String) -> SourceConfig { configs[id] ?? SourceConfig() }

    public func update(_ id: String, _ change: (inout SourceConfig) -> Void) {
        var c = config(for: id)
        change(&c)
        c.volume = min(1, max(0, c.volume))
        // The default is not stored, so a source nobody touched leaves no entry behind.
        configs[id] = c == SourceConfig() ? nil : c
        save()
    }

    public func forget(_ id: String) {
        enabled.removeAll { $0 == id }
        configs[id] = nil
        save()
    }

    private func save() {
        store.set(try? JSONEncoder().encode(Stored(enabled: enabled, configs: configs)), forKey: Self.key)
    }
}

/// What the lock screen and headphone buttons need to know about one connected source.
public struct MediaSourceCandidate: Equatable {
    public var id: String
    /// From the source's STATUS: its play/pause/next/previous controls work. nil = unknown.
    public var controlsAvailable: Bool?
    public var playing: Bool
    /// When `playing` last changed (a source that just started playing is "more recent").
    public var playingChangedAt: TimeInterval

    public init(id: String, controlsAvailable: Bool?, playing: Bool, playingChangedAt: TimeInterval) {
        self.id = id; self.controlsAvailable = controlsAvailable
        self.playing = playing; self.playingChangedAt = playingChangedAt
    }
}

public enum MediaSourceChooser {
    /// The source play/pause/next/previous go to: among sources whose STATUS says controls are
    /// available, one that is playing over one that isn't, and among those the one that most
    /// recently started playing (or, if none is playing, most recently stopped). Ties keep the
    /// `current` choice, then the earlier source in the list. Sources without controls are never chosen.
    public static func choose(_ candidates: [MediaSourceCandidate], current: String? = nil) -> String? {
        let eligible = candidates.filter { $0.controlsAvailable == true }
        guard var best = eligible.first else { return nil }
        for c in eligible.dropFirst() where beats(c, best, current: current) { best = c }
        return best.id
    }

    private static func beats(_ a: MediaSourceCandidate, _ b: MediaSourceCandidate, current: String?) -> Bool {
        if a.playing != b.playing { return a.playing }
        if a.playingChangedAt != b.playingChangedAt { return a.playingChangedAt > b.playingChangedAt }
        return a.id == current && b.id != current
    }
}
