import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Which of this PC's addresses to put in the Bonjour TXT record, mirroring the Mac advertiser:
/// `addr` is the IPv4 of the best real interface (wired Ethernet first), so the phone doesn't pick
/// a Docker bridge or VPN address; `ts` is the Tailscale address, if any.
public struct HostAddresses: Equatable {
    public var addr: String?
    public var tailscale: String?
}

public struct InterfaceAddress: Equatable {
    public var name: String
    public var ipv4: UInt32   // host byte order
    public init(name: String, ipv4: UInt32) { self.name = name; self.ipv4 = ipv4 }

    public var text: String { "\(ipv4 >> 24).\((ipv4 >> 16) & 0xFF).\((ipv4 >> 8) & 0xFF).\(ipv4 & 0xFF)" }
}

public enum NetworkAddresses {
    /// Tailscale hands out 100.64.0.0/10.
    static func isTailscale(_ a: UInt32) -> Bool { a & 0xFFC0_0000 == 0x6440_0000 }
    static func isLinkLocal(_ a: UInt32) -> Bool { a & 0xFFFF_0000 == 0xA9FE_0000 }

    /// Interfaces that never carry the LAN the phone is on.
    static func isVirtual(_ name: String) -> Bool {
        ["lo", "docker", "br-", "veth", "virbr", "vmnet", "vboxnet", "lxc", "lxd", "cni", "flannel",
         "cali", "podman", "tun", "tap", "wg", "zt", "ppp", "vnet", "tailscale"]
            .contains { name == $0 || name.hasPrefix($0) }
    }

    static func isWired(_ name: String) -> Bool {
        ["en", "eth"].contains { name.hasPrefix($0) }
    }

    /// Picks `addr` and `ts` from the interfaces that are up. `defaultRoute` (the interface the
    /// default route leaves by) wins ties within wired and within wireless.
    public static func pick(from interfaces: [InterfaceAddress], defaultRoute: String?) -> HostAddresses {
        let tailscale = interfaces.first { isTailscale($0.ipv4) }
        let real = interfaces.filter { !isVirtual($0.name) && !isTailscale($0.ipv4) && !isLinkLocal($0.ipv4) }
        func ordered(_ list: [InterfaceAddress]) -> [InterfaceAddress] {
            list.filter { $0.name == defaultRoute } + list.filter { $0.name != defaultRoute }
        }
        let wired = ordered(real.filter { isWired($0.name) })
        let other = ordered(real.filter { !isWired($0.name) })
        return HostAddresses(addr: (wired + other).first?.text, tailscale: tailscale?.text)
    }

    public static func current() -> HostAddresses {
        pick(from: upInterfaces(), defaultRoute: defaultRouteInterface())
    }

    /// IPv4 addresses of interfaces that are up (loopback excluded).
    static func upInterfaces() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var out: [InterfaceAddress] = []
        var p = head
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = UInt32(ifa.pointee.ifa_flags)
            // IFF_UP 0x1, IFF_LOOPBACK 0x8 on both Linux and Darwin.
            guard flags & 0x1 != 0, flags & 0x8 == 0,
                  let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            out.append(InterfaceAddress(name: String(cString: ifa.pointee.ifa_name), ipv4: a))
        }
        return out
    }

    /// The interface of the lowest-metric default route in /proc/net/route text.
    public static func defaultRouteInterface(procNetRoute text: String? = nil) -> String? {
        guard let text = text ?? (try? String(contentsOfFile: "/proc/net/route", encoding: .utf8)) else { return nil }
        var best: (iface: String, metric: Int)?
        for line in text.split(separator: "\n").dropFirst() {
            // Iface Destination Gateway Flags RefCnt Use Metric Mask ...
            let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard f.count >= 8, f[1] == "00000000", f[7] == "00000000" else { continue }
            let metric = Int(f[6]) ?? 0
            if best == nil || metric < best!.metric { best = (String(f[0]), metric) }
        }
        return best?.iface
    }
}
