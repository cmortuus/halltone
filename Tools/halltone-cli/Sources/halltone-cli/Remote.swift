import Foundation
import Darwin
import HalltoneCore

/// `halltone-cli remote HOST[:PORT] --code N pause|resume`: sends REMOTE_CONTROL, retrying with the
/// same request id every 300 ms (as the Linux sender does), and prints the Mac's answer.
/// Exits 0 for an answer that means the request was handled (paused, notPlaying, resumed,
/// resumeSkipped) and 1 for failed / badPairingCode / disabled / no answer.
func runRemote(target: String, pairingCode: UInt32, name: String, command: RemoteCommand, timeout: Double) throws {
    var host = target
    var port = String(Constants.defaultPort)
    if target.hasPrefix("["), let close = target.firstIndex(of: "]") { // [v6]:port
        host = String(target[target.index(after: target.startIndex)..<close])
        let rest = target[target.index(after: close)...]
        if rest.hasPrefix(":") { port = String(rest.dropFirst()) }
    } else if target.filter({ $0 == ":" }).count == 1, let colon = target.firstIndex(of: ":") {
        host = String(target[..<colon]); port = String(target[target.index(after: colon)...])
    }

    var hints = addrinfo(); hints.ai_socktype = SOCK_DGRAM
    var res: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(host, port, &hints, &res)
    guard rc == 0, let info = res else { throw RemoteError.resolve(String(cString: gai_strerror(rc))) }
    defer { freeaddrinfo(res) }
    let fd = socket(info.pointee.ai_family, SOCK_DGRAM, 0)
    guard fd >= 0 else { throw RemoteError.socket(errno) }
    defer { close(fd) }
    guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { throw RemoteError.socket(errno) }
    var tv = timeval(tv_sec: 0, tv_usec: 300_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let requestID = UInt32.random(in: 1...UInt32.max)
    let request = Packet(seq: 1, session: 0, message: .remoteControl(pairingCode: pairingCode, command: command,
                                                                       requestID: requestID, peerName: name)).encode()
    let deadline = Date().addingTimeInterval(timeout)
    var buf = [UInt8](repeating: 0, count: 2048)
    var attempts = 0
    while Date() < deadline {
        attempts += 1
        _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        // Wait up to 300 ms for the ack, then resend the same request id.
        let n = recv(fd, &buf, buf.count, 0)
        if n < 0, errno != EAGAIN, errno != EWOULDBLOCK { usleep(300_000) } // e.g. connection refused
        guard n > 0, let packet = Packet.decode(Data(buf[0..<n])),
              case .remoteControlAck(let id, let result) = packet.message, id == requestID else { continue }
        print("\(result)")
        exit(handled(result) ? 0 : 1)
    }
    FileHandle.standardError.write("no answer from \(target) after \(attempts) tries (is Halltone running there, and is the host reachable?)\n".data(using: .utf8)!)
    exit(1)
}

private func handled(_ r: RemoteResult) -> Bool {
    switch r {
    case .paused, .notPlaying, .resumed, .resumeSkipped: return true
    case .failed, .badPairingCode, .disabled: return false
    }
}

enum RemoteError: Error, CustomStringConvertible {
    case resolve(String), socket(Int32)
    var description: String {
        switch self {
        case .resolve(let m): return "can't resolve host: \(m)"
        case .socket(let e): return "socket: \(String(cString: strerror(e)))"
        }
    }
}
