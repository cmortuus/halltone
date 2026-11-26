import Foundation
import HalltoneCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A bare UDP client standing in for the phone: IPv4 loopback socket, decodes whatever the sender
/// sends back. Portable, so the same tests run on macOS and Ubuntu CI.
final class TestClient {
    private let fd: Int32
    private var dest = sockaddr_in()
    private var seq: UInt32 = 0
    let session: UInt32 = 0x1234

    init(port: UInt16) {
        #if canImport(Darwin)
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        #else
        fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #endif
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        dest.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    }

    deinit { close(fd) }

    func send(_ message: Message) {
        seq &+= 1
        let data = Packet(seq: seq, session: session, message: message).encode()
        data.withUnsafeBytes { raw in
            var d = dest
            _ = withUnsafePointer(to: &d) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// The next packet, or nil after `timeout` seconds.
    func receive(timeout: TimeInterval = 1) -> Packet? {
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0, let p = Packet.decode(Data(buf[0..<n])) { return p }
        }
        return nil
    }

    /// Packets until `match` returns a value (others are skipped), or nil on timeout.
    func receive<T>(timeout: TimeInterval = 2, until match: (Packet) -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let p = receive(timeout: max(0.05, deadline.timeIntervalSinceNow)) else { continue }
            if let v = match(p) { return v }
        }
        return nil
    }
}
