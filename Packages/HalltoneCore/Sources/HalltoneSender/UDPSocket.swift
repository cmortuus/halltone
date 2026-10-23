#if os(macOS)
import Foundation
import Darwin
import CHalltone

/// Minimal dual-stack UDP socket. `sendto` from the encode thread costs a few microseconds,
/// versus the per-packet dispatch/allocation overhead of NWConnection.send.
final class UDPSocket {
    enum Failure: Error, CustomStringConvertible {
        case socket(Int32), bind(Int32)
        var description: String {
            switch self {
            case .socket(let e): return "socket(): \(String(cString: strerror(e)))"
            case .bind(let e): return "bind(): \(String(cString: strerror(e)))"
            }
        }
    }

    let fd: Int32

    /// Which of this Mac's addresses each peer last sent to. Replies go out from that address:
    /// with Ethernet and Wi-Fi on the same subnet the route would pick Ethernet's, and a phone
    /// that talks to the Wi-Fi address drops replies from another one.
    private struct PeerKey: Hashable {
        var a: UInt64, b: UInt64, port: UInt16
        init(_ s: sockaddr_storage) {
            var s = s
            (a, b, port) = withUnsafeBytes(of: &s) { raw in
                guard raw.load(fromByteOffset: 1, as: UInt8.self) == UInt8(AF_INET6) else { return (0, 0, 0) }
                return (raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                        raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self),
                        raw.loadUnaligned(fromByteOffset: 2, as: UInt16.self))
            }
        }
    }
    private struct Local { var bytes: (UInt64, UInt64) }
    private var localFor: [PeerKey: Local] = [:]
    private let localLock = NSLock()

    init(port: UInt16) throws {
        fd = socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        var off: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // DSCP EF (46) → Wi-Fi WMM "voice" access category: highest priority, and access points
        // deliver it promptly to clients in power save.
        var tclass: Int32 = 46 << 2
        setsockopt(fd, IPPROTO_IPV6, IPV6_TCLASS, &tclass, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_IP, IP_TOS, &tclass, socklen_t(MemoryLayout<Int32>.size))
        var svc: Int32 = NET_SERVICE_TYPE_VO
        setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &svc, socklen_t(MemoryLayout<Int32>.size))
        var bufSize: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard rc == 0 else { let e = errno; close(fd); throw Failure.bind(e) }
        es_udp_enable_pktinfo(fd)
    }

    deinit { close(fd) }

    /// Returns bytes received, 0 on timeout, -1 on error.
    func receive(into buf: UnsafeMutableRawPointer, capacity: Int, from: inout sockaddr_storage) -> Int {
        var local = Local(bytes: (0, 0))
        var hasLocal: Int32 = 0
        let n = withUnsafeMutableBytes(of: &local.bytes) { lb in
            Int(es_udp_recv(fd, buf, capacity, &from, lb.baseAddress!.assumingMemoryBound(to: UInt8.self), &hasLocal))
        }
        if n < 0 { return (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1 }
        if hasLocal != 0 {
            let key = PeerKey(from)
            localLock.lock()
            if localFor.count > 256 { localFor.removeAll() } // stale peers; current ones re-add
            localFor[key] = local
            localLock.unlock()
        }
        return n
    }

    @discardableResult
    func send(_ ptr: UnsafeRawPointer, _ len: Int, to addr: sockaddr_storage) -> Int {
        var a = addr
        localLock.lock()
        let local = localFor[PeerKey(addr)]
        localLock.unlock()
        guard var local else {
            let len32 = socklen_t(addr.ss_len)
            return withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, ptr, len, 0, $0, len32) }
            }
        }
        return withUnsafeBytes(of: &local.bytes) { lb in
            Int(es_udp_send_from(fd, ptr, len, &a, lb.baseAddress!.assumingMemoryBound(to: UInt8.self)))
        }
    }

    func shutdownForClose() { Darwin.shutdown(fd, SHUT_RDWR) }

    static func describe(_ addr: sockaddr_storage) -> String {
        var a = addr
        let len32 = socklen_t(addr.ss_len)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var serv = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let hostCount = socklen_t(host.count), servCount = socklen_t(serv.count)
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len32, &host, hostCount, &serv, servCount, NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard rc == 0 else { return "?" }
        var h = String(cString: host)
        if h.hasPrefix("::ffff:") { h = String(h.dropFirst(7)) }
        return "\(h):\(String(cString: serv))"
    }
}
#endif
