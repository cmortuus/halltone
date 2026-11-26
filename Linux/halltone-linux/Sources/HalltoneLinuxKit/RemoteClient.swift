import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import HalltoneCore

public struct RemoteSendOutcome: Equatable {
    public var requestID: UInt32 = 0
    public var target: String?
    /// The Mac's answer; nil when none arrived (or there was nobody to ask).
    public var result: RemoteResult?
    public var attempts = 0
    public var elapsedMs = 0
    public var error: String?
}

public protocol RemoteSending: AnyObject {
    func send(_ command: RemoteCommand) -> RemoteSendOutcome
}

/// REMOTE_CONTROL over UDP, as `halltone-cli remote` does it: the same request id is resent every
/// `timeout` (300 ms) up to `attempts` (5) times until the matching ack arrives.
public final class UDPRemoteClient: RemoteSending {
    private let locator: MacLocator
    private let pairingCode: UInt32
    private let peerName: String
    public var timeoutMs = 300
    public var maxAttempts = 5

    public init(locator: MacLocator, pairingCode: UInt32, peerName: String) {
        self.locator = locator
        self.pairingCode = pairingCode
        self.peerName = peerName
    }

    public func send(_ command: RemoteCommand) -> RemoteSendOutcome {
        var out = RemoteSendOutcome()
        guard let (target, _) = locator.resolve() else {
            out.error = locator.lastProblem ?? "no Mac to ask"
            return out
        }
        out.target = target.description
        var hints = addrinfo()
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_DGRAM
        #else
        hints.ai_socktype = Int32(SOCK_DGRAM.rawValue)
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(target.host, String(target.port), &hints, &res)
        guard rc == 0, let info = res else {
            out.error = "can't resolve \(target.host): \(String(cString: gai_strerror(rc)))"
            locator.invalidate()
            return out
        }
        defer { freeaddrinfo(res) }
        #if canImport(Darwin)
        let fd = socket(info.pointee.ai_family, SOCK_DGRAM, 0)
        #else
        let fd = socket(info.pointee.ai_family, Int32(SOCK_DGRAM.rawValue), 0)
        #endif
        guard fd >= 0 else { out.error = "socket: \(String(cString: strerror(errno)))"; return out }
        defer { close(fd) }
        guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            out.error = "connect: \(String(cString: strerror(errno)))"
            return out
        }
        var tv = timeval(tv_sec: 0, tv_usec: .init(timeoutMs * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let id = UInt32.random(in: 1...UInt32.max)
        out.requestID = id
        let started = monotonicNow()
        var buf = [UInt8](repeating: 0, count: 2048)
        for attempt in 1...maxAttempts {
            out.attempts = attempt
            let request = Packet(seq: UInt32(attempt), session: 0,
                                 message: .remoteControl(pairingCode: pairingCode, command: command,
                                                         requestID: id, peerName: peerName)).encode()
            _ = request.withUnsafeBytes { rawSend(fd, $0.baseAddress, $0.count) }
            let attemptEnd = monotonicNow() + Double(timeoutMs) / 1000
            // Wait out the timeout for the matching ack (other packets don't end the wait).
            while monotonicNow() < attemptEnd {
                let n = recv(fd, &buf, buf.count, 0)
                if n < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                    usleep(50_000)   // e.g. connection refused (nothing listening yet)
                    continue
                }
                guard n > 0, let p = Packet.decode(Data(buf[0..<n])),
                      case .remoteControlAck(let ackID, let result) = p.message, ackID == id else { continue }
                out.result = result
                out.elapsedMs = Int((monotonicNow() - started) * 1000)
                return out
            }
        }
        out.elapsedMs = Int((monotonicNow() - started) * 1000)
        out.error = "no answer from \(target) after \(maxAttempts) tries"
        locator.invalidate()
        return out
    }
}

/// The C `send`, which `UDPRemoteClient.send(_:)` shadows inside the class.
private func rawSend(_ fd: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.send(fd, p, n, 0)
    #else
    return Glibc.send(fd, p, n, 0)
    #endif
}
