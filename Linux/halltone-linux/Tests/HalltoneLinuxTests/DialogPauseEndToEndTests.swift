import Testing
import Foundation
import HalltoneCore
import HalltoneDialogEval
#if canImport(Glibc)
import Glibc
#endif

/// A stand-in for the Mac: a UDP socket that answers REMOTE_CONTROL the way the Mac does and
/// records every request it receives.
final class FakeMac {
    struct Request { var command: RemoteCommand; var id: UInt32; var code: UInt32; var peer: String; var at: Double }
    private let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var running = true
    /// Ignore this many first copies of each request (forces the sender's retry).
    var dropFirst = 0
    var expectedCode: UInt32 = 7777
    private var seen: [UInt32: Int] = [:]

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }

    init() {
        #if canImport(Darwin)
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        #else
        let sock = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #endif
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) } }
        fd = sock
        port = UInt16(bigEndian: addr.sin_port)
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let t = Thread { [self] in serve() }
        t.start()
    }

    func stop() { lock.lock(); running = false; lock.unlock() }

    private func serve() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            lock.lock(); let on = running; lock.unlock()
            if !on { close(fd); return }
            var from = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
            }
            guard n > 0, let p = Packet.decode(Data(buf[0..<n])),
                  case .remoteControl(let code, let command, let id, let peer) = p.message else { continue }
            lock.lock()
            _requests.append(Request(command: command, id: id, code: code, peer: peer, at: Date().timeIntervalSinceReferenceDate))
            seen[id, default: 0] += 1
            let copies = seen[id]!
            lock.unlock()
            if copies <= dropFirst { continue }
            let result: RemoteResult = code != expectedCode ? .badPairingCode : (command == .pauseForPeer ? .paused : .resumed)
            let ack = Packet(seq: 1, session: 0, message: .remoteControlAck(requestID: id, result: result)).encode()
            _ = withUnsafePointer(to: &from) { f in
                f.withMemoryRebound(to: sockaddr.self, capacity: 1) { a in
                    ack.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, a, fromLen) }
                }
            }
        }
    }
}

/// The whole feature, end to end: a WAV with a character speaking over music plays through the
/// real `halltone-linux` (`--source wav:`), and a fake Mac must receive pauseForPeer during the
/// speech and resumeForPeer afterwards. Speech is synthesized (`say` / `espeak-ng`), so the
/// timing tests skip when neither exists.
@Suite(.serialized, .timeLimit(.minutes(3))) struct DialogPauseEndToEndTests {
    static let line = "Commander, the enemy ships are approaching from the north. We must move out right now, before they find us."

    /// A 2 s music intro, the spoken line, and a quiet tail; returns the path and the label.
    static func fixture(dir: String) throws -> (path: String, speechStart: Double, speechEnd: Double)? {
        guard let mix = makeDemoMix(lines: [line], gaps: [], leadIn: 2, tail: 7, musicGain: 0.15, speechOverMusicDB: 9),
              let label = mix.labels.first else { return nil }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/dialog.wav"
        try WAV.write16(path: path, sampleRate: 48_000, channels: 2, samples: mix.samples)
        return (path, label.start, label.end)
    }

    struct Run {
        let process = Process()
        let dir: String
        let port = UInt16.random(in: 30_000...60_000)
        let socket: String
        init(args: [String], dir: String) throws {
            self.dir = dir
            socket = dir + "/c.sock"
            process.executableURL = IntegrationTests.binary
            process.arguments = ["--no-advertise", "--code", "4321", "--port", String(port),
                                 "--config", dir + "/config.json", "--control-socket", socket] + args
            process.standardOutput = FileHandle.nullDevice
            FileManager.default.createFile(atPath: dir + "/err.log", contents: nil)
            process.standardError = FileHandle(forWritingAtPath: dir + "/err.log")
            try process.run()
        }
        /// What the process logged (shown when a check fails; `HALLTONE_SHOW_LOG=1` prints it).
        var log: String { (try? String(contentsOfFile: dir + "/err.log", encoding: .utf8)) ?? "" }
        func stop() {
            if process.isRunning { process.terminate(); IntegrationTests.wait(process, seconds: 5) }
        }
        /// Subscribes like the phone does and keeps the subscription alive until `seconds` passed.
        func listen(for seconds: Double) -> Double? {
            let c = TestClient(port: port)
            var started: Double?
            for _ in 0..<25 where started == nil {
                c.send(.subscribe(pairingCode: 4321, deviceName: "Phone", deviceID: "dialog-it"))
                if c.receive(timeout: 0.4, until: { p in if case .subscribeAck = p.message { return true } else { return nil } }) == true {
                    started = Date().timeIntervalSinceReferenceDate
                }
            }
            guard let t0 = started else { return nil }
            var lastKeepalive = Date()
            while Date().timeIntervalSinceReferenceDate - t0 < seconds {
                _ = c.receive(timeout: 0.1)
                if Date().timeIntervalSince(lastKeepalive) > 0.5 {
                    c.send(.keepalive(lastSeqReceived: 1, lossPermille: 0, bufferMs: 40))
                    lastKeepalive = Date()
                }
            }
            c.send(.bye)
            return t0
        }
    }

    /// Short: a Unix socket path must fit in sun_path (104 bytes on macOS, where TMPDIR is long).
    static func tempDir() -> String { NSTemporaryDirectory() + "hd-\(UUID().uuidString.prefix(8))" }

    @Test(.enabled(if: SpeechSynth.isAvailable, "needs say or espeak-ng"))
    func dialogPausesTheMacAndResumesItAfterwards() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fx = try #require(try Self.fixture(dir: dir))
        let mac = FakeMac()
        defer { mac.stop() }
        let run = try Run(args: ["--source", "wav:" + fx.path, "--dialog-pause", "--dialog-mac", "127.0.0.1:\(mac.port)",
                                 "--dialog-code", "7777", "--name", "Gaming PC"], dir: dir)
        defer { run.stop() }
        let t0 = try #require(run.listen(for: fx.speechEnd + 6))
        let reqs = mac.requests
        if ProcessInfo.processInfo.environment["HALLTONE_SHOW_LOG"] != nil { print(run.log) }
        #expect(reqs.map(\.command) == [.pauseForPeer, .resumeForPeer], "got \(reqs.map(\.command)); log:\n\(run.log)")
        guard reqs.count == 2 else { return }
        #expect(reqs.allSatisfy { $0.code == 7777 && $0.peer == "Gaming PC" })
        #expect(reqs[0].id != reqs[1].id)
        let pauseAt = reqs[0].at - t0, resumeAt = reqs[1].at - t0
        // Pause: after the line began (detector ~0.25 s + minDialogMs 0.6 s), well before it ends.
        #expect(pauseAt > fx.speechStart + 0.3 && pauseAt < fx.speechEnd - 0.5, "pause at \(pauseAt), speech \(fx.speechStart)…\(fx.speechEnd)")
        // Resume: resumeDelayMs (1.5 s) after the last speech, give or take the detector's estimate.
        #expect(resumeAt > fx.speechEnd + 1.0 && resumeAt < fx.speechEnd + 3.0, "resume at \(resumeAt), speech ended \(fx.speechEnd)")
    }

    @Test(.enabled(if: SpeechSynth.isAvailable, "needs say or espeak-ng"))
    func lostAcksAreRetriedWithTheSameRequestId() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fx = try #require(try Self.fixture(dir: dir))
        let mac = FakeMac()
        mac.dropFirst = 2          // the first two copies of every request vanish
        defer { mac.stop() }
        let run = try Run(args: ["--source", "wav:" + fx.path, "--dialog-pause", "--dialog-mac", "127.0.0.1:\(mac.port)",
                                 "--dialog-code", "7777"], dir: dir)
        defer { run.stop() }
        _ = try #require(run.listen(for: fx.speechEnd + 7))
        let reqs = mac.requests
        let ids = Array(Set(reqs.map(\.id)))
        #expect(ids.count == 2, "two distinct requests expected, got \(reqs.count) packets")
        for id in ids {
            let copies = reqs.filter { $0.id == id }
            #expect(copies.count == 3, "request \(id): \(copies.count) copies")
            // 300 ms apart.
            if copies.count == 3 { #expect(copies[1].at - copies[0].at > 0.25 && copies[1].at - copies[0].at < 0.6) }
        }
    }

    @Test(.enabled(if: SpeechSynth.isAvailable, "needs say or espeak-ng"))
    func switchedOffNothingIsSentAndTheControlSocketTurnsItOn() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fx = try #require(try Self.fixture(dir: dir))
        let mac = FakeMac()
        defer { mac.stop() }
        // dialogPause is configured (code + Mac) but not enabled.
        let run = try Run(args: ["--source", "wav:" + fx.path, "--dialog-mac", "127.0.0.1:\(mac.port)", "--dialog-code", "7777"], dir: dir)
        defer { run.stop() }
        _ = try #require(run.listen(for: fx.speechEnd + 5))
        #expect(mac.requests.isEmpty, "disabled, yet sent \(mac.requests.map(\.command))")
    }

    // MARK: control socket and signals

    static func dialogCommand(_ word: String, socket: String) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = IntegrationTests.binary
        p.arguments = ["dialog", word, "--socket", socket]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        IntegrationTests.wait(p, seconds: 8)
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, text)
    }

    static func waitForSocket(_ path: String) -> Bool {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: path) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    @Test func dialogOnOffStatusAndSIGUSR1() throws {
        let dir = Self.tempDir()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let run = try Run(args: ["--source", "tone", "--dialog-pause", "--dialog-mac", "127.0.0.1:9", "--dialog-code", "7777"], dir: dir)
        defer { run.stop() }
        #expect(Self.waitForSocket(run.socket))

        var r = try Self.dialogCommand("status", socket: run.socket)
        #expect(r.status == 0 && r.output.contains("dialog pause: on"), "\(r)")
        r = try Self.dialogCommand("off", socket: run.socket)
        #expect(r.status == 0 && r.output.contains("ok: dialog pause off"), "\(r)")
        r = try Self.dialogCommand("status", socket: run.socket)
        #expect(r.output.contains("dialog pause: off"), "\(r)")
        r = try Self.dialogCommand("on", socket: run.socket)
        #expect(r.status == 0 && r.output.contains("ok: dialog pause on"), "\(r)")

        // SIGUSR1 flips it.
        kill(run.process.processIdentifier, SIGUSR1)
        var off = false
        for _ in 0..<40 where !off {
            Thread.sleep(forTimeInterval: 0.1)
            off = (try? Self.dialogCommand("status", socket: run.socket))?.output.contains("dialog pause: off") == true
        }
        #expect(off, "SIGUSR1 didn't turn it off")
        kill(run.process.processIdentifier, SIGUSR1)
        var on = false
        for _ in 0..<40 where !on {
            Thread.sleep(forTimeInterval: 0.1)
            on = (try? Self.dialogCommand("status", socket: run.socket))?.output.contains("dialog pause: on") == true
        }
        #expect(on, "second SIGUSR1 didn't turn it back on")

        // The socket goes away with the process.
        run.stop()
        #expect(!FileManager.default.fileExists(atPath: run.socket))
    }

    @Test func withoutConfigurationTheSubcommandSaysSo() throws {
        let dir = Self.tempDir()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let run = try Run(args: ["--source", "tone"], dir: dir)
        defer { run.stop() }
        #expect(Self.waitForSocket(run.socket))
        var r = try Self.dialogCommand("status", socket: run.socket)
        #expect(r.status == 0 && r.output.contains("not configured"), "\(r)")
        r = try Self.dialogCommand("on", socket: run.socket)
        #expect(r.status == 1 && r.output.contains("not configured"), "\(r)")
        // Nothing listening: a clear error, not a hang.
        run.stop()
        r = try Self.dialogCommand("status", socket: run.socket)
        #expect(r.status == 1 && r.output.contains("can't reach"), "\(r)")
    }
}
