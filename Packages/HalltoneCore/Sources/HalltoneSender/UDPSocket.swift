#if os(macOS)
import Foundation
import Darwin

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

    init(port: UInt16) throws {
        fd = socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        var off: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
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
    }

    deinit { close(fd) }

    /// Returns bytes received, 0 on timeout, -1 on error.
    func receive(into buf: UnsafeMutableRawPointer, capacity: Int, from: inout sockaddr_storage) -> Int {
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, buf, capacity, 0, $0, &len) }
        }
        if n < 0 { return (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1 }
        return n
    }

    @discardableResult
    func send(_ ptr: UnsafeRawPointer, _ len: Int, to addr: sockaddr_storage) -> Int {
        var a = addr
        let len32 = socklen_t(addr.ss_len)
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, ptr, len, 0, $0, len32) }
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
