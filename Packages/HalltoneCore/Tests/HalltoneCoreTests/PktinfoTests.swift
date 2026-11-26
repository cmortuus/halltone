import Testing
import Foundation
import CHalltone
#if canImport(Glibc)
import Glibc
#endif

#if canImport(Glibc)
private let datagramType = Int32(SOCK_DGRAM.rawValue)   // an enum on Glibc
#else
private let datagramType = SOCK_DGRAM
#endif

/// The pktinfo helpers (CHalltone/udp_pktinfo.c) over loopback: a datagram sent to a dual-stack
/// socket from IPv4 reports the local address it was sent to (::ffff:127.0.0.1), and
/// es_udp_send_from can reply from it.
@Suite struct PktinfoTests {
    @Test func reportsLocalAddressAndRepliesFromIt() throws {
        let server = socket(AF_INET6, datagramType, 0)
        #expect(server >= 0)
        defer { close(server) }
        var off: Int32 = 0
        setsockopt(server, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var any6 = sockaddr_in6()
        any6.sin6_family = sa_family_t(AF_INET6)
        any6.sin6_addr = in6addr_any
        any6.sin6_port = 0
        let bound = withUnsafePointer(to: &any6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        #expect(bound == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &any6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &len) }
        }
        #expect(es_udp_enable_pktinfo(server) == 0)

        let client = socket(AF_INET, datagramType, 0)
        #expect(client >= 0)
        defer { close(client) }
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var dst = sockaddr_in()
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = any6.sin6_port
        dst.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let payload: [UInt8] = [1, 2, 3, 4]
        let sent = withUnsafePointer(to: &dst) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(client, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(sent == 4)

        var from = sockaddr_storage()
        var local = [UInt8](repeating: 0, count: 16)
        var hasLocal: Int32 = 0
        var buf = [UInt8](repeating: 0, count: 64)
        let n = es_udp_recv(server, &buf, buf.count, &from, &local, &hasLocal)
        #expect(n == 4)
        #expect(Array(buf[0..<4]) == payload)
        #expect(hasLocal == 1)
        #expect(local == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1])

        // Reply from that address; the IPv4 client must receive it.
        let replyBytes: [UInt8] = [9, 8]
        let r = es_udp_send_from(server, replyBytes, 2, &from, local)
        #expect(r == 2)
        var reply = [UInt8](repeating: 0, count: 8)
        #expect(recv(client, &reply, reply.count, 0) == 2)
        #expect(Array(reply[0..<2]) == [9, 8])
    }
}
