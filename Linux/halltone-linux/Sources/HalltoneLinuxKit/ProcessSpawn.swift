import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The one way halltone-linux starts a helper program (`busctl`, `pactl`, `parec`, `avahi-*`).
///
/// Swift Foundation's `Pipe` on Linux does not reliably close its descriptors, and 0.1.0 leaked two
/// per `busctl` call (about one call a second) until the process hit 1024 open files and capture and
/// Avahi failed (#25). So the pipes here are plain `pipe(2)` descriptors, close-on-exec, and each
/// end has exactly one owner that closes it on every path: the parent's copy of the child's end
/// right after launch (or on a failed launch), and the read end when it has been drained.
enum Spawn {
    struct Started {
        let process: Process
        /// Read ends the caller now owns; release them with `drain` or `readChunks` (both close).
        let stdout: Int32?
        let stderr: Int32?
    }

    struct SpawnError: Error, CustomStringConvertible { let description: String }

    static func makePipe() -> (read: Int32, write: Int32)? {
        var fds: [Int32] = [-1, -1]
        #if os(Linux)
        // Atomic: other threads spawn children too, and a child forked between pipe() and fcntl()
        // would inherit the write end and keep the reader from ever seeing EOF.
        guard pipe2(&fds, O_CLOEXEC) == 0 else { return nil }
        #else
        guard pipe(&fds) == 0 else { return nil }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        #endif
        return (fds[0], fds[1])
    }

    /// Starts `executable`, optionally capturing stdout / stderr (otherwise /dev/null). stdin is /dev/null.
    static func start(_ executable: String, _ args: [String], captureStdout: Bool, captureStderr: Bool,
                      onExit: ((Process) -> Void)? = nil) throws -> Started {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        var outPipe: (read: Int32, write: Int32)?
        var errPipe: (read: Int32, write: Int32)?
        func closeAll() {
            for pipe in [outPipe, errPipe] { if let pipe { close(pipe.read); close(pipe.write) } }
        }
        if captureStdout {
            guard let pipe = makePipe() else { closeAll(); throw SpawnError(description: "pipe: \(String(cString: strerror(errno)))") }
            outPipe = pipe
            p.standardOutput = FileHandle(fileDescriptor: pipe.write, closeOnDealloc: false)
        } else {
            p.standardOutput = FileHandle.nullDevice
        }
        if captureStderr {
            guard let pipe = makePipe() else { closeAll(); throw SpawnError(description: "pipe: \(String(cString: strerror(errno)))") }
            errPipe = pipe
            p.standardError = FileHandle(fileDescriptor: pipe.write, closeOnDealloc: false)
        } else {
            p.standardError = FileHandle.nullDevice
        }
        if let onExit { p.terminationHandler = onExit }
        do { try p.run() } catch { closeAll(); throw error }
        // The child has its own copies; the parent must not keep the write ends or EOF never comes.
        if let outPipe { close(outPipe.write) }
        if let errPipe { close(errPipe.write) }
        return Started(process: p, stdout: outPipe?.read, stderr: errPipe?.read)
    }

    /// Calls `handler` with each chunk until EOF, `shouldStop()` turns true (checked every 100 ms)
    /// or an error; then closes `fd`.
    static func readChunks(_ fd: Int32, shouldStop: () -> Bool = { false }, _ handler: (Data) -> Void) {
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 16384)
        while !shouldStop() {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, 100)
            if r < 0 { if errno == EINTR { continue }; return }
            if r == 0 { continue }
            let n = read(fd, &buf, buf.count)
            if n > 0 { handler(Data(buf[0..<n])) }
            else if n == 0 { return }
            else if errno != EINTR && errno != EAGAIN { return }
        }
    }

    /// Everything until EOF (see `readChunks`); closes `fd`.
    static func drain(_ fd: Int32, shouldStop: () -> Bool = { false }) -> Data {
        var all = Data()
        readChunks(fd, shouldStop: shouldStop) { all.append($0) }
        return all
    }
}

private final class Flag {
    private let lock = NSLock(); private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

/// Runs a command with a hard deadline. stdout and stderr are drained concurrently (a full pipe
/// can't wedge the child), and a command that doesn't exit in time is terminated, then killed:
/// the caller gets nil ("no answer") and never hangs. A wedged D-Bus must not stall STATUS or a
/// REMOTE_CONTROL ack. Every descriptor it opens is closed before it returns or shortly after
/// (a reader whose pipe a grandchild still holds gives up within 100 ms of the caller leaving).
public enum CommandRunner {
    public struct Result {
        public var status: Int32
        public var stdoutData: Data
        public var stderrData: Data
        public var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
        public var stderr: String { String(decoding: stderrData, as: UTF8.self) }
    }

    public static func run(_ executable: String, _ args: [String], timeout: TimeInterval) -> Result? {
        let exited = DispatchSemaphore(value: 0)
        guard let s = try? Spawn.start(executable, args, captureStdout: true, captureStderr: true, onExit: { _ in exited.signal() }),
              let outFD = s.stdout, let errFD = s.stderr else { return nil }
        let p = s.process

        let lock = NSLock()
        var outData = Data(), errData = Data()
        let abandon = Flag()
        let drained = DispatchGroup()
        for (fd, isOut) in [(outFD, true), (errFD, false)] {
            drained.enter()
            Thread.detachNewThread {
                let d = Spawn.drain(fd, shouldStop: { abandon.isSet })
                lock.lock(); if isOut { outData = d } else { errData = d }; lock.unlock()
                drained.leave()
            }
        }
        var finished = exited.wait(timeout: .now() + timeout) == .success
        if !finished {
            p.terminate()
            if exited.wait(timeout: .now() + 0.5) != .success {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.5)
            }
        }
        // The readers end at EOF; don't wait long in case a grandchild holds the pipe open.
        _ = drained.wait(timeout: .now() + (finished ? 1.0 : 0.2))
        abandon.set()   // a straggler closes its descriptor within 100 ms
        guard finished else { return nil }
        lock.lock(); defer { lock.unlock() }
        return Result(status: p.terminationStatus, stdoutData: outData, stderrData: errData)
    }
}
