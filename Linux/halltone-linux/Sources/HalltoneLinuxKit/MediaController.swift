import Foundation
import HalltoneCore
#if canImport(Glibc)
import Glibc
#endif

// Media control on Linux over MPRIS (the D-Bus interface Firefox, Chrome, mpv, VLC, Spotify and
// others implement). `MediaController` picks the player and drives it with explicit Pause / Play
// from the real `PlaybackStatus`; it never toggles blindly. It is the one place that knows about
// players, so phone CONTROL, REMOTE_CONTROL (as `ExplicitPlaybackEnvironment`) and dialog pause on
// the same PC (#20) all go through it.

public enum MPRISStatus: String, Equatable {
    case playing = "Playing", paused = "Paused", stopped = "Stopped"
}

public struct MPRISPlayer: Equatable {
    /// `org.mpris.MediaPlayer2.firefox.instance_1_42`
    public var bus: String
    /// The player's own name ("Mozilla Firefox"); may be empty.
    public var identity: String
    public var status: MPRISStatus
    /// `mpris:trackid` (may be empty).
    public var trackID: String
    public var title: String

    public init(bus: String, identity: String = "", status: MPRISStatus, trackID: String = "", title: String = "") {
        self.bus = bus; self.identity = identity; self.status = status; self.trackID = trackID; self.title = title
    }

    /// `firefox.instance_1_42`: the bus name without the MPRIS prefix.
    public var shortName: String {
        bus.hasPrefix(MPRISNames.prefix) ? String(bus.dropFirst(MPRISNames.prefix.count)) : bus
    }

    /// Case-insensitive substring match on the bus name or identity.
    public func matches(_ text: String) -> Bool {
        let t = text.lowercased()
        guard !t.isEmpty else { return false }
        return bus.lowercased().contains(t) || identity.lowercased().contains(t)
    }
}

public enum MPRISNames {
    public static let prefix = "org.mpris.MediaPlayer2."
}

public enum MPRISCommand: String {
    case play = "Play", pause = "Pause", next = "Next", previous = "Previous"
}

/// The D-Bus side, behind a protocol so tests use a fake.
public protocol MPRISBackend: AnyObject {
    /// Every MPRIS player now on the session bus. Throws when the bus can't be asked.
    func players() throws -> [MPRISPlayer]
    /// Calls the method on that player; false if it failed.
    func send(_ command: MPRISCommand, to bus: String) -> Bool
}

/// What the phone's lock screen (and `halltone-linux media`) can ask for.
public enum MediaCommand: Equatable {
    case play, pause, playPause, next, previous
}

public final class MediaController: ExplicitPlaybackEnvironment {
    public let backend: MPRISBackend
    /// A substring of the bus name or identity that pins the player; nil: any.
    public let pin: String?
    /// Players whose bus name or identity contains any of these are never touched.
    public let ignore: [String]

    private let clock: () -> TimeInterval
    private let sleeper: (TimeInterval) -> Void
    private let lock = NSLock()
    private var snapshot: [MPRISPlayer] = []
    private var snapshotOK = false
    private var snapshotAt: TimeInterval?
    /// When each player was first seen playing in its current run: "most recently started" wins.
    private var startedAt: [String: TimeInterval] = [:]
    /// The player we last chose or paused, for Play when nothing is playing.
    private var lastActive: String?
    /// When STATUS (or anything else) last asked what the players are doing. The background poll
    /// only refreshes while that is recent, so an idle sender never touches D-Bus.
    private var lastDemandAt: TimeInterval?
    private let demandWindow: TimeInterval = 15
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "com.halltone.mpris")

    public init(backend: MPRISBackend = BusctlBackend(), pin: String? = nil, ignore: [String] = [],
                clock: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 },
                sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.backend = backend
        let p = pin?.trimmingCharacters(in: .whitespaces)
        self.pin = (p?.isEmpty ?? true) ? nil : p
        self.ignore = ignore.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self.clock = clock
        self.sleeper = sleeper
    }

    // MARK: - Snapshot

    /// Asks the bus and updates what we know. False if the bus couldn't be asked.
    @discardableResult
    public func refresh() -> Bool {
        let result = Result { try backend.players() }
        let t = clock()
        lock.lock(); defer { lock.unlock() }
        switch result {
        case .success(let list):
            snapshot = list.sorted { $0.bus < $1.bus }
            snapshotOK = true
            let alive = Set(list.map(\.bus))
            for p in list {
                if p.status == .playing { if startedAt[p.bus] == nil { startedAt[p.bus] = t } } else { startedAt[p.bus] = nil }
            }
            startedAt = startedAt.filter { alive.contains($0.key) }
            if let a = lastActive, !alive.contains(a) { lastActive = nil }
        case .failure:
            snapshot = []
            snapshotOK = false
            startedAt = [:]
        }
        snapshotAt = t
        return snapshotOK
    }

    private func refreshIfOlder(than age: TimeInterval) {
        lock.lock(); let at = snapshotAt; lock.unlock()
        if at == nil || clock() - at! > age { refresh() }
    }

    /// Whether the config lets us touch this player.
    public func isEligible(_ p: MPRISPlayer) -> Bool {
        if ignore.contains(where: { p.matches($0) }) { return false }
        if let pin { return p.matches(pin) }
        return true
    }

    /// The player to act on: the playing one that started most recently; otherwise the last one we
    /// used; otherwise the first by name. Pin and ignore apply. Uses the last snapshot.
    public func chosen() -> MPRISPlayer? {
        lock.lock(); defer { lock.unlock() }
        return choose()
    }

    private func choose() -> MPRISPlayer? {
        let eligible = snapshot.filter(isEligible)
        let playing = eligible.filter { $0.status == .playing }
        if !playing.isEmpty {
            // Sorted by bus already, so a tie goes to the first by name.
            return playing.max { (startedAt[$0.bus] ?? 0) < (startedAt[$1.bus] ?? 0) }
        }
        if let a = lastActive, let p = eligible.first(where: { $0.bus == a }) { return p }
        return eligible.first
    }

    /// Every player the config lets us touch, from the last snapshot.
    public func eligiblePlayers() -> [MPRISPlayer] {
        lock.lock(); defer { lock.unlock() }
        return snapshot.filter(isEligible)
    }

    private func remember(_ p: MPRISPlayer) { lock.lock(); lastActive = p.bus; lock.unlock() }

    // MARK: - Reading

    public struct Entry: Equatable {
        public var player: MPRISPlayer
        public var ignored: Bool
        /// The one commands would go to now.
        public var chosen: Bool
    }

    /// Every player with whether it is ignored / chosen (refreshes first). nil: the bus can't be asked.
    public func listing() -> [Entry]? {
        guard refresh() else { return nil }
        let c = chosen()
        lock.lock(); defer { lock.unlock() }
        return snapshot.map { Entry(player: $0, ignored: !isEligible($0), chosen: $0.bus == c?.bus) }
    }

    /// An MPRIS player exists that we may control. Uses the last snapshot (refreshing once if there
    /// is none), so it is cheap enough for STATUS.
    public func controlsAvailable() -> Bool {
        noteDemand()
        refreshIfOlder(than: demandWindow)
        lock.lock(); defer { lock.unlock() }
        return snapshot.contains(where: isEligible)
    }

    /// Whether an eligible player is playing, from the last snapshot; nil when nothing can be said
    /// (no eligible player, or the bus can't be asked).
    public func peekPlaying() -> Bool? {
        noteDemand()
        refreshIfOlder(than: demandWindow)
        lock.lock(); defer { lock.unlock() }
        let eligible = snapshot.filter(isEligible)
        guard snapshotOK, !eligible.isEmpty else { return nil }
        return eligible.contains { $0.status == .playing }
    }

    private func noteDemand() { lock.lock(); lastDemandAt = clock(); lock.unlock() }

    /// Keeps the snapshot fresh in the background (every `interval` seconds) so STATUS never waits on
    /// D-Bus, but only while someone is asking: each refresh spawns `busctl` several times, and an
    /// idle sender (no phone connected) must not do that once a second for nothing.
    public func startPolling(interval: TimeInterval = 1) {
        lock.lock()
        guard pollTimer == nil else { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        pollTimer = timer
        lock.unlock()
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); let asked = self.lastDemandAt; self.lock.unlock()
            guard let asked, self.clock() - asked <= self.demandWindow else { return }
            self.refresh()
        }
        timer.resume()
    }

    public func stopPolling() {
        lock.lock(); let t = pollTimer; pollTimer = nil; lock.unlock()
        t?.cancel()
    }

    // MARK: - Commands (phone, CLI)

    /// Carries out a command on the chosen player. Pause and Play are explicit: pausing something
    /// that isn't playing, or playing something that is, succeeds without doing anything.
    @discardableResult
    public func perform(_ command: MediaCommand) -> Bool {
        guard refresh(), let p = chosen() else { return false }
        remember(p)
        let playing = p.status == .playing
        switch command {
        case .pause: return playing ? backend.send(.pause, to: p.bus) : true
        case .play: return playing ? true : backend.send(.play, to: p.bus)
        case .playPause: return backend.send(playing ? .pause : .play, to: p.bus)
        case .next: return backend.send(.next, to: p.bus)
        case .previous: return backend.send(.previous, to: p.bus)
        }
    }

    // MARK: - ExplicitPlaybackEnvironment

    public func now() -> TimeInterval { clock() }
    public func sleep(_ seconds: TimeInterval) { sleeper(seconds) }

    public func playbackState() -> ExplicitPlayback {
        guard refresh() else { return .unknown }
        guard let p = chosen() else { return .notPlaying }
        return p.status == .playing ? .playing : .notPlaying
    }

    public func pausePlayback() -> String? {
        guard refresh(), let p = chosen(), p.status == .playing else { return nil }
        remember(p)
        guard backend.send(.pause, to: p.bus) else { return nil }
        // Players apply Pause asynchronously: wait (briefly) until it shows, so the mark we keep
        // describes a pause that really happened.
        var waited = 0.0
        while true {
            if refresh() {
                lock.lock(); let now = snapshot.first { $0.bus == p.bus }; lock.unlock()
                guard let now else { return nil }
                if now.status != .playing { return Self.token(for: now) }
            }
            if waited >= 1.0 { return nil }
            sleeper(0.1); waited += 0.1
        }
    }

    public func resumePlayback(token: String) -> Bool {
        guard let bus = Self.parse(token)?.bus else { return false }
        return backend.send(.play, to: bus)
    }

    public func isStillPaused(token: String) -> Bool {
        guard let want = Self.parse(token), refresh() else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let p = snapshot.first(where: { $0.bus == want.bus }) else { return false }
        return p.status == .paused && p.trackID == want.trackID && p.title == want.title
    }

    static func token(for p: MPRISPlayer) -> String { [p.bus, p.trackID, p.title].joined(separator: "\u{1F}") }
    static func parse(_ token: String) -> (bus: String, trackID: String, title: String)? {
        let parts = token.components(separatedBy: "\u{1F}")
        return parts.count == 3 ? (parts[0], parts[1], parts[2]) : nil
    }
}

// MARK: - busctl backend

/// MPRIS over the session bus with `busctl --user` (ships with systemd, so Ubuntu has it).
public final class BusctlBackend: MPRISBackend {
    private let path: String?
    private let timeout: TimeInterval
    private var identities: [String: String] = [:]
    private let lock = NSLock()

    /// `executable` replaces the `busctl` found on PATH (tests use a command that never exits).
    public init(executable: String? = nil, timeout: TimeInterval = 2) {
        path = executable ?? Self.find("busctl")
        self.timeout = timeout
    }

    static func find(_ name: String) -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        return (dirs + ["/usr/bin", "/bin"]).map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public struct BusError: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    public func players() throws -> [MPRISPlayer] {
        let list = try run(["--no-pager", "--no-legend", "list"])
        let names = list.split(separator: "\n").compactMap { $0.split(separator: " ", maxSplits: 1).first.map(String.init) }
            .filter { $0.hasPrefix(MPRISNames.prefix) }
        var out: [MPRISPlayer] = []
        for bus in names {
            // A player can vanish between the list and the query: skip it, don't fail.
            guard let json = try? run(["--json=short", "call", bus, "/org/mpris/MediaPlayer2",
                                       "org.freedesktop.DBus.Properties", "GetAll", "s", "org.mpris.MediaPlayer2.Player"]),
                  let props = Self.properties(fromJSON: json) else { continue }
            out.append(MPRISPlayer(bus: bus, identity: identity(of: bus), status: props.status,
                                   trackID: props.trackID, title: props.title))
        }
        return out
    }

    public func send(_ command: MPRISCommand, to bus: String) -> Bool {
        (try? run(["call", bus, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", command.rawValue])) != nil
    }

    private func identity(of bus: String) -> String {
        lock.lock(); let known = identities[bus]; lock.unlock()
        if let known { return known }
        guard let json = try? run(["--json=short", "get-property", bus, "/org/mpris/MediaPlayer2",
                                   "org.mpris.MediaPlayer2", "Identity"]),
              let value = Self.plain(json) as? String else { return "" }
        lock.lock(); identities[bus] = value; lock.unlock()
        return value
    }

    // MARK: parsing (static, so tests feed it recorded busctl output)

    /// Strips busctl's `{"type":…,"data":…}` wrappers.
    static func plain(_ json: String) -> Any? {
        guard let data = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return unwrap(obj)
    }

    private static func unwrap(_ x: Any) -> Any {
        if let d = x as? [String: Any] {
            if d.count == 2, let inner = d["data"], d["type"] is String { return unwrap(inner) }
            return d.mapValues(unwrap)
        }
        if let a = x as? [Any] { return a.map(unwrap) }
        return x
    }

    private static func find(key: String, in x: Any) -> [String: Any]? {
        if let d = x as? [String: Any] {
            if d[key] != nil { return d }
            for v in d.values { if let f = find(key: key, in: v) { return f } }
        } else if let a = x as? [Any] {
            for v in a { if let f = find(key: key, in: v) { return f } }
        }
        return nil
    }

    static func properties(fromJSON json: String) -> (status: MPRISStatus, trackID: String, title: String)? {
        guard let root = plain(json), let props = find(key: "PlaybackStatus", in: root),
              let s = props["PlaybackStatus"] as? String else { return nil }
        let meta = props["Metadata"] as? [String: Any] ?? [:]
        func text(_ key: String) -> String {
            if let s = meta[key] as? String { return s }
            if let a = meta[key] as? [Any], let s = a.first as? String { return s }
            return ""
        }
        return (MPRISStatus(rawValue: s) ?? .stopped, text("mpris:trackid"), text("xesam:title"))
    }

    // MARK: process

    private func run(_ args: [String]) throws -> String {
        guard let path else { throw BusError(description: "busctl not found (it ships with systemd)") }
        guard let r = CommandRunner.run(path, ["--user"] + args, timeout: timeout) else {
            throw BusError(description: "busctl \(args.prefix(3).joined(separator: " ")) didn't answer in \(timeout) s (or can't run)")
        }
        guard r.status == 0 else { throw BusError(description: "busctl \(args.prefix(3).joined(separator: " ")) failed (\(r.status)): \(r.stderr)") }
        return r.stdout
    }
}
