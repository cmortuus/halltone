import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import HalltoneCore

public struct MacTarget: Equatable, CustomStringConvertible {
    public var host: String
    public var port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// One `_halltone._udp` service from `avahi-browse`.
public struct AvahiService: Equatable {
    public var name: String
    public var address: String
    public var port: UInt16
}

/// Finds the Mac that REMOTE_CONTROL goes to: the configured host or Bonjour name, or, when none
/// is configured, the only Halltone Mac `avahi-browse _halltone._udp` finds.
public final class MacLocator {
    private let setting: String?
    private let selfName: String
    private let lock = NSLock()
    private var cached: (target: MacTarget, how: String, at: Double)?
    public private(set) var lastProblem: String?

    public init(setting: String?, selfName: String) {
        self.setting = setting?.trimmingCharacters(in: .whitespaces).isEmpty == true ? nil : setting
        self.selfName = selfName
    }

    /// The target and how it was found ("configured", "discovered"), from a short cache.
    public func resolve() -> (target: MacTarget, how: String)? {
        lock.lock()
        if let c = cached, monotonicNow() - c.at < 300 { lock.unlock(); return (c.target, c.how) }
        lock.unlock()
        guard let found = lookup() else { return nil }
        lock.lock(); cached = (found.target, found.how, monotonicNow()); lock.unlock()
        return found
    }

    /// Forget the cached address (the Mac didn't answer: it may have a new one).
    public func invalidate() { lock.lock(); cached = nil; lock.unlock() }

    public var current: String? { lock.lock(); defer { lock.unlock() }; return cached.map { "\($0.target) (\($0.how))" } }

    private func lookup() -> (target: MacTarget, how: String)? {
        if let setting {
            let (host, port) = Self.splitHostPort(setting)
            if Self.canResolve(host) {
                lastProblem = nil
                return (MacTarget(host: host, port: port ?? Constants.defaultPort), "configured")
            }
            // Not a resolvable host: maybe the Bonjour service name ("Caleb's MacBook").
            let services = Self.browse()
            if let s = services.first(where: { $0.name.caseInsensitiveCompare(host) == .orderedSame }) {
                lastProblem = nil
                return (MacTarget(host: s.address, port: s.port), "bonjour name")
            }
            lastProblem = "dialogPause.mac \"\(setting)\" is neither a resolvable host nor the name of a Halltone service on this network"
            return nil
        }
        let services = Self.browse()
        switch Self.choose(services, selfName: selfName, localAddresses: Self.localAddresses()) {
        case .found(let s):
            lastProblem = nil
            return (MacTarget(host: s.address, port: s.port), "discovered")
        case .none:
            lastProblem = "no Halltone Mac found with avahi-browse _halltone._udp (is Halltone running on the Mac, avahi-utils installed here? or set dialogPause.mac)"
            return nil
        case .ambiguous(let names):
            lastProblem = "several Halltone hosts found (\(names.joined(separator: ", "))): set dialogPause.mac to the Mac's name or address"
            return nil
        }
    }

    // MARK: - Pure helpers (tested)

    public static func splitHostPort(_ text: String) -> (host: String, port: UInt16?) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
            let host = String(t[t.index(after: t.startIndex)..<close])
            let rest = t[t.index(after: close)...]
            return (host, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) : nil)
        }
        if t.filter({ $0 == ":" }).count == 1, let colon = t.firstIndex(of: ":") {
            return (String(t[..<colon]), UInt16(t[t.index(after: colon)...]))
        }
        return (t, nil)
    }

    /// Parses `avahi-browse -rtp` output: `=;iface;IPv4;name;type;domain;host;address;port;"txt"`.
    /// avahi escapes bytes as `\DDD` (decimal). IPv4 resolved entries only, one per name and address.
    public static func parseAvahi(_ output: String) -> [AvahiService] {
        func unescape(_ s: String) -> String {
            var bytes: [UInt8] = []
            let u = Array(s.utf8)
            var i = 0
            while i < u.count {
                if u[i] == 0x5C, i + 3 < u.count,
                   let d = Int(String(decoding: u[(i + 1)...(i + 3)], as: UTF8.self)) {
                    bytes.append(UInt8(truncatingIfNeeded: d)); i += 4
                } else { bytes.append(u[i]); i += 1 }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        var out: [AvahiService] = []
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("=") {
            let f = line.split(separator: ";", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 9, f[2] == "IPv4", let port = UInt16(f[8]) else { continue }
            let s = AvahiService(name: unescape(f[3]), address: f[7], port: port)
            if !out.contains(s) { out.append(s) }
        }
        return out
    }

    public enum Choice: Equatable { case found(AvahiService), none, ambiguous([String]) }

    /// The only service that isn't this PC (by name or by one of its addresses).
    public static func choose(_ services: [AvahiService], selfName: String, localAddresses: Set<String>) -> Choice {
        let others = services.filter {
            $0.name.caseInsensitiveCompare(selfName) != .orderedSame && !localAddresses.contains($0.address)
        }
        let names = Array(Set(others.map(\.name))).sorted()
        switch names.count {
        case 0: return .none
        case 1: return .found(others.first { $0.name == names[0] }!)
        default: return .ambiguous(names)
        }
    }

    // MARK: - System

    static func canResolve(_ host: String) -> Bool {
        var hints = addrinfo()
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_DGRAM
        #else
        hints.ai_socktype = Int32(SOCK_DGRAM.rawValue)
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &res)
        if rc == 0 { freeaddrinfo(res) }
        return rc == 0
    }

    static func localAddresses() -> Set<String> {
        var set: Set<String> = ["127.0.0.1"]
        for i in NetworkAddresses.upInterfaces() {
            set.insert([24, 16, 8, 0].map { String((i.ipv4 >> UInt32($0)) & 0xFF) }.joined(separator: "."))
        }
        return set
    }

    static func browse() -> [AvahiService] {
        guard let exe = Self.find("avahi-browse") else { return [] }
        guard let r = CommandRunner.run(exe, ["-r", "-t", "-p", "_halltone._udp"], timeout: 6) else { return [] }
        return parseAvahi(r.stdout)
    }

    static func find(_ tool: String) -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/usr/bin", "/usr/local/bin"]
        return dirs.map { $0 + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
