#if os(macOS)
import Foundation
import dnssd
import Network
import Darwin
import os
import HalltoneCore

private let log = Logger(subsystem: Constants.logSubsystem, category: "Bonjour")

/// Registers `_halltone._udp` via the dnssd C API (the UDP socket is ours, so NWListener's
/// built-in advertising can't be used).
///
/// The TXT record carries `addr`: this Mac's IPv4 address on its preferred interface (wired
/// Ethernet when connected). A Mac on both Ethernet and Wi-Fi is reachable at two addresses, and
/// if the phone picks the Wi-Fi one, every packet takes two wireless hops and shares the Mac's
/// radio with Bluetooth (AirPods). Receivers connect to `addr` when present.
///
/// It also carries `ts`: this Mac's Tailscale address, if Tailscale is running. Bonjour doesn't
/// cross Tailscale, so the phone remembers `ts` at home and uses it when the Mac isn't on the
/// local network (away, on cellular).
final class BonjourAdvertiser {
    private var ref: DNSServiceRef?
    private let queue: DispatchQueue
    private let name: String
    private let port: UInt16
    private let baseTXT: [String: String]
    private var monitor: NWPathMonitor?
    private var currentAddr: String?
    private var currentTailscale: String?

    init(name: String, port: UInt16, txtValues: [String: String], queue: DispatchQueue) {
        self.queue = queue
        self.name = name
        self.port = port
        self.baseTXT = txtValues
        let addr = Self.preferredIPv4(for: nil)
        currentAddr = addr
        currentTailscale = Self.tailscaleIPv4()
        register(addr: addr)
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let a = Self.preferredIPv4(for: path)
            let ts = Self.tailscaleIPv4()
            if a != self.currentAddr || ts != self.currentTailscale {
                log.notice("addresses changed: \(a ?? "none", privacy: .public), Tailscale \(ts ?? "none", privacy: .public)")
                self.currentAddr = a
                self.currentTailscale = ts
                self.updateTXT(addr: a)
            }
        }
        m.start(queue: queue)
        monitor = m
    }

    deinit {
        monitor?.cancel()
        if let ref { DNSServiceRefDeallocate(ref) }
    }

    private func makeTXT(addr: String?) -> Data {
        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        defer { TXTRecordDeallocate(&txt) }
        var values = baseTXT
        if let addr { values["addr"] = addr }
        if let ts = currentTailscale { values["ts"] = ts }
        for (k, v) in values {
            let bytes = Array(v.utf8)
            bytes.withUnsafeBufferPointer { TXTRecordSetValue(&txt, k, UInt8(min(bytes.count, 255)), $0.baseAddress) }
        }
        return Data(bytes: TXTRecordGetBytesPtr(&txt), count: Int(TXTRecordGetLength(&txt)))
    }

    private func register(addr: String?) {
        let txt = makeTXT(addr: addr)
        let err = txt.withUnsafeBytes { raw in
            DNSServiceRegister(&ref, 0, 0, name, Constants.serviceType, nil, nil, port.bigEndian,
                               UInt16(raw.count), raw.baseAddress, nil, nil)
        }
        if err == kDNSServiceErr_NoError, let ref {
            DNSServiceSetDispatchQueue(ref, queue)
            log.notice("advertising \(self.name, privacy: .public) on \(self.port), addr \(addr ?? "none", privacy: .public), Tailscale \(self.currentTailscale ?? "none", privacy: .public)")
        } else {
            log.error("DNSServiceRegister failed: \(err)")
        }
    }

    private func updateTXT(addr: String?) {
        guard let ref else { return }
        let txt = makeTXT(addr: addr)
        let err = txt.withUnsafeBytes { raw in
            DNSServiceUpdateRecord(ref, nil, 0, UInt16(raw.count), raw.baseAddress, 0)
        }
        if err != kDNSServiceErr_NoError { log.error("TXT update failed: \(err)") }
    }

    /// This Mac's Tailscale IPv4 (Tailscale hands out 100.64.0.0/10 addresses on a utun
    /// interface), or nil when Tailscale isn't running.
    static func tailscaleIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var p = head
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name).hasPrefix("utun"),
                  let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  ifa.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // 100.64.0.0/10
            guard a & 0xFFC0_0000 == 0x6440_0000 else { continue }
            return "\(a >> 24).\((a >> 16) & 0xFF).\((a >> 8) & 0xFF).\(a & 0xFF)"
        }
        return nil
    }

    /// IPv4 of the best interface: wired Ethernet first, then the system's preferred order.
    /// Never the Tailscale address: that's `ts`, for when the phone is away.
    static func preferredIPv4(for path: NWPath?) -> String? {
        let interfaces: [(name: String, wired: Bool)]
        if let path {
            interfaces = path.availableInterfaces.map { ($0.name, $0.type == .wiredEthernet) }
        } else {
            // No path yet: fall back to the interface of the default route.
            interfaces = (defaultRouteInterface().map { [($0, false)] } ?? [])
        }
        let ordered = interfaces.filter(\.wired) + interfaces.filter { !$0.wired }
        for i in ordered {
            if let a = ipv4(of: i.name), !a.hasPrefix("100.") || !isTailscale(a) { return a }
        }
        return nil
    }

    private static func isTailscale(_ a: String) -> Bool {
        let parts = a.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && parts[1] & 0xC0 == 64
    }

    private static func defaultRouteInterface() -> String? {
        // The primary interface is the one carrying the default route; read it from getifaddrs
        // ordering is unreliable, so ask the routing socket via a tiny helper.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/route")
        p.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(separator: "\n").first { $0.contains("interface:") }?
            .split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func ipv4(of interface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var p = head
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name) == interface,
                  let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  ifa.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(sa.pointee.sa_len)
            if getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
#endif
