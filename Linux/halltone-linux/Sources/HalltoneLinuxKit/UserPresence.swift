import Foundation

// "Is someone using this PC?" for the phone's Auto latency mode (#34). The Mac answers with
// `UserPresence.swift` (HalltoneMac); this is the same idea on a Linux desktop, with the same
// thresholds: input in the last 20 s is "recent input", input in the last 180 s on an unlocked
// session is "user at the PC", and locking the screen clears both.
//
// Every query goes through `CommandRunner` (busctl) on `PresenceMonitor`'s own queue and is cached.
// STATUS reads the cache and never waits for D-Bus.

/// What the desktop says right now. nil members are "can't tell", which is not the same as "away".
public struct PresenceSample: Equatable {
    /// Seconds since the last keyboard/mouse input (Mutter's IdleMonitor).
    public var idleSeconds: TimeInterval?
    /// The screen is locked (GNOME ScreenSaver, else logind `LockedHint`).
    public var locked: Bool?
    /// logind's `IdleHint` for this session: the coarse fallback when there is no idle time.
    public var sessionIdle: Bool?
    /// Something holds an idle inhibitor (a game, Steam/Proton, a video player). Gamepad input never
    /// reaches Mutter's idle time, so a running game is how controller-only play shows up.
    public var idleInhibited: Bool?

    public init(idleSeconds: TimeInterval? = nil, locked: Bool? = nil, sessionIdle: Bool? = nil, idleInhibited: Bool? = nil) {
        self.idleSeconds = idleSeconds; self.locked = locked; self.sessionIdle = sessionIdle; self.idleInhibited = idleInhibited
    }
}

/// The two flags STATUS carries. nil: unknown, reported as "no flag" (never as a reason to look away).
public struct Presence: Equatable {
    public var inputRecent: Bool?
    public var atPC: Bool?

    public init(inputRecent: Bool? = nil, atPC: Bool? = nil) { self.inputRecent = inputRecent; self.atPC = atPC }

    public static let recentInputLimit: TimeInterval = 20   // UserPresence.recentInputLimit on the Mac
    public static let idleLimit: TimeInterval = 180         // UserPresence.idleLimit on the Mac

    /// Same rules as the Mac, with what Linux can know.
    public init(_ s: PresenceSample) {
        if s.locked == true { self.init(inputRecent: false, atPC: false); return }
        let inhibited = s.idleInhibited == true
        if let idle = s.idleSeconds {
            // `inputRecent` stays what the keyboard and mouse say; an idle inhibitor only keeps "at the PC".
            self.init(inputRecent: idle < Self.recentInputLimit,
                      atPC: (idle < Self.idleLimit || inhibited) ? true : (s.locked == nil ? nil : false))
            return
        }
        if inhibited { self.init(inputRecent: nil, atPC: true); return }
        // No idle time (not GNOME): logind's session IdleHint says "idle for a while" or not. It can't
        // say input was in the last 20 s, so that flag stays unknown.
        if let hint = s.sessionIdle { self.init(inputRecent: nil, atPC: hint ? false : (s.locked == nil ? nil : true)); return }
        self.init()
    }
}

/// The D-Bus side, behind a protocol so tests use a fake.
public protocol PresenceBackend: AnyObject {
    /// Throws nothing: a source that can't answer is nil in the sample.
    func sample() -> PresenceSample
}

/// Reads presence with `busctl` (ships with systemd): GNOME's Mutter IdleMonitor and ScreenSaver on
/// the session bus, logind on the system bus as the fallback.
public final class BusctlPresenceBackend: PresenceBackend {
    private let path: String?
    private let timeout: TimeInterval

    public init(executable: String? = nil, timeout: TimeInterval = 1.5) {
        path = executable ?? BusctlBackend.find("busctl")
        self.timeout = timeout
    }

    public func sample() -> PresenceSample {
        var s = PresenceSample()
        if let out = run(["--user", "call", "org.gnome.Mutter.IdleMonitor", "/org/gnome/Mutter/IdleMonitor/Core",
                          "org.gnome.Mutter.IdleMonitor", "GetIdletime"]), let ms = Self.number(out) {
            s.idleSeconds = ms / 1000
        }
        if let out = run(["--user", "call", "org.gnome.ScreenSaver", "/org/gnome/ScreenSaver",
                          "org.gnome.ScreenSaver", "GetActive"]) {
            s.locked = Self.bool(out)
        }
        // Idle inhibitor: GNOME's session manager (flag 8 = idle), else logind's inhibitor list.
        if let out = run(["--user", "call", "org.gnome.SessionManager", "/org/gnome/SessionManager",
                          "org.gnome.SessionManager", "IsInhibited", "u", "8"]) {
            s.idleInhibited = Self.bool(out)
        } else if let out = run(["--system", "call", "org.freedesktop.login1", "/org/freedesktop/login1",
                                 "org.freedesktop.login1.Manager", "ListInhibitors"]) {
            s.idleInhibited = Self.userIdleInhibitor(out, uid: UInt32(getuid()))
        }
        // logind: only asked for what GNOME didn't answer. `auto` is the caller's own session.
        if s.locked == nil, let out = logind("LockedHint") { s.locked = Self.bool(out) }
        if s.idleSeconds == nil, let out = logind("IdleHint") { s.sessionIdle = Self.bool(out) }
        return s
    }

    private func logind(_ property: String) -> String? {
        run(["--system", "get-property", "org.freedesktop.login1", "/org/freedesktop/login1/session/auto",
             "org.freedesktop.login1.Session", property])
    }

    private func run(_ args: [String]) -> String? {
        guard let path, let r = CommandRunner.run(path, ["--no-pager"] + args, timeout: timeout), r.status == 0 else { return nil }
        return r.stdout
    }

    /// `t 1234` (busctl's reply to GetIdletime, milliseconds) → 1234.
    static func number(_ output: String) -> Double? {
        let parts = output.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard parts.count == 2, parts[0] == "t" else { return nil }
        return Double(parts[1])
    }

    /// busctl's `ListInhibitors` reply (`a(ssssuu) 2 "what" "who" "why" "mode" uid pid …`): is there a
    /// blocking inhibitor of idle or sleep held by one of this user's processes?
    static func userIdleInhibitor(_ output: String, uid: UInt32) -> Bool? {
        var tokens: [String] = []
        var cur = "", inQuote = false, escaped = false
        for ch in output {
            if inQuote {
                if escaped { cur.append(ch); escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { tokens.append("\"" + cur); cur = ""; inQuote = false }
                else { cur.append(ch) }
            } else if ch == "\"" { inQuote = true }
            else if ch == " " || ch == "\n" { if !cur.isEmpty { tokens.append(cur); cur = "" } }
            else { cur.append(ch) }
        }
        guard tokens.count >= 2, tokens[0] == "a(ssssuu)", let n = Int(tokens[1]) else { return nil }
        let rest = Array(tokens.dropFirst(2))
        guard rest.count >= n * 6 else { return nil }
        for i in 0..<n {
            let e = Array(rest[(i * 6)..<(i * 6 + 6)])
            let what = e[0].dropFirst().split(separator: ":"), mode = e[3].dropFirst()
            if mode == "block", UInt32(e[4]) == uid, what.contains(where: { $0 == "idle" || $0 == "sleep" }) { return true }
        }
        return false
    }

    /// `b true` → true.
    static func bool(_ output: String) -> Bool? {
        let parts = output.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard parts.count == 2, parts[0] == "b" else { return nil }
        return parts[1] == "true" ? true : parts[1] == "false" ? false : nil
    }
}

/// The cached answer the sender reads. Reads never block and never run a helper; a refresh runs on
/// this object's own queue, at most one at a time and at most every `interval`, and only while
/// `wanted` says someone is listening (so an idle sender never touches D-Bus). A sample older than
/// `maxAge` reads as unknown.
public final class PresenceMonitor {
    public let backend: PresenceBackend
    private let interval: TimeInterval
    private let maxAge: TimeInterval
    private let wanted: () -> Bool
    private let clock: () -> TimeInterval
    private let lock = NSLock()
    private var cached = Presence()
    private var sampledAt: TimeInterval?
    private var inFlight = false
    private let queue = DispatchQueue(label: "com.halltone.presence")

    public init(backend: PresenceBackend = BusctlPresenceBackend(), interval: TimeInterval = 3, maxAge: TimeInterval = 12,
                wanted: @escaping () -> Bool = { true },
                clock: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }) {
        self.backend = backend; self.interval = interval; self.maxAge = maxAge; self.wanted = wanted; self.clock = clock
    }

    /// The last answer (nil members: unknown). Starts a background refresh if it is stale and wanted.
    public func current() -> Presence {
        kick()
        lock.lock(); defer { lock.unlock() }
        guard let at = sampledAt, clock() - at <= maxAge else { return Presence() }
        return cached
    }

    public func userAtPC() -> Bool { current().atPC == true }
    public func inputRecent() -> Bool { current().inputRecent == true }

    private func kick() {
        guard wanted() else { return }
        lock.lock()
        let stale = sampledAt == nil || clock() - sampledAt! >= interval
        if !stale || inFlight { lock.unlock(); return }
        inFlight = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let p = Presence(self.backend.sample())
            let t = self.clock()
            self.lock.lock(); self.cached = p; self.sampledAt = t; self.inFlight = false; self.lock.unlock()
        }
    }

    /// Takes a sample now, on the caller's thread (tests, `halltone-linux` diagnostics).
    @discardableResult
    public func refreshNow() -> Presence {
        let p = Presence(backend.sample())
        let t = clock()
        lock.lock(); cached = p; sampledAt = t; lock.unlock()
        return p
    }
}
