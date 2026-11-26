import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The daemon's control socket: one line in (`on`, `off`, `status`), one reply, close. It's how
/// `halltone-linux dialog on|off|status` reaches the running service.
public enum ControlSocket {
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let dir = environment["XDG_RUNTIME_DIR"], dir.hasPrefix("/") { return dir + "/halltone-linux.sock" }
        return "/tmp/halltone-linux-\(getuid()).sock"
    }

    static func makeSocket() -> Int32 {
        #if canImport(Darwin)
        return socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        return socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
    }

    /// Runs `body` with the address; false if the path is too long for a socket address.
    static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Void) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
        }
        withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return true
    }

    /// Client: sends `line`, returns the reply; nil (with `error`) when nothing is listening.
    public static func request(path: String, line: String, timeout: Double = 5) -> (reply: String?, error: String?) {
        let fd = makeSocket()
        guard fd >= 0 else { return (nil, "socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var connected = false
        let fits = withAddress(path) { a, len in connected = connect(fd, a, len) == 0 }
        guard fits else { return (nil, "socket path too long: \(path)") }
        guard connected else { return (nil, "can't reach halltone-linux at \(path): \(String(cString: strerror(errno))) (is it running?)") }
        let data = Array((line + "\n").utf8)
        _ = data.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            reply.append(contentsOf: buf[0..<n])
        }
        return (String(decoding: reply, as: UTF8.self), nil)
    }
}

public final class ControlServer {
    private let path: String
    private let handler: (String) -> String
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var running = false

    public init(path: String, handler: @escaping (String) -> String) {
        self.path = path
        self.handler = handler
    }

    /// Binds and starts serving. Returns a problem description instead of throwing: a busy or
    /// unwritable socket must not stop the audio stream.
    public func start() -> String? {
        // Another instance owns the path? Then leave it alone; a dead one's file is replaced.
        if FileManager.default.fileExists(atPath: path) {
            if ControlSocket.request(path: path, line: "status", timeout: 1).reply != nil {
                return "another halltone-linux already answers on \(path); not serving the control socket"
            }
            unlink(path)
        }
        let s = ControlSocket.makeSocket()
        guard s >= 0 else { return "socket: \(String(cString: strerror(errno)))" }
        var bound = false
        let fits = ControlSocket.withAddress(path) { a, len in bound = bind(s, a, len) == 0 }
        guard fits else { close(s); return "control socket path too long: \(path)" }
        guard bound else { let e = String(cString: strerror(errno)); close(s); return "can't bind \(path): \(e)" }
        chmod(path, 0o600)
        guard listen(s, 4) == 0 else { close(s); unlink(path); return "listen: \(String(cString: strerror(errno)))" }
        fd = s
        lock.lock(); running = true; lock.unlock()
        let t = Thread { [self] in serve() }
        t.name = "com.halltone.control"
        t.start()
        return nil
    }

    public func stop() {
        lock.lock(); let was = running; running = false; lock.unlock()
        if was { unlink(path) }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func serve() {
        while isRunning {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 200) <= 0 { continue }
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var line = [UInt8]()
            var byte: UInt8 = 0
            while line.count < 128, recv(c, &byte, 1, 0) == 1, byte != 0x0A { line.append(byte) }
            let command = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let reply = Array((handler(command) + "\n").utf8)
            _ = reply.withUnsafeBytes { send(c, $0.baseAddress, $0.count, 0) }
            close(c)
        }
        close(fd)
    }
}
