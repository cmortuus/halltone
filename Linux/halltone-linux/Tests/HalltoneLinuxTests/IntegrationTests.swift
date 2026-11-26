import Testing
import Foundation
import HalltoneCore
#if canImport(Glibc)
import Glibc
#endif

/// End to end: the real `halltone-linux` executable with `--source tone` (no PulseAudio) and a
/// minimal UDP receiver (TestClient) that subscribes, checks the ACK, decodes the frames and
/// checks the tone. Runs the same on macOS and on Ubuntu CI.
@Suite(.serialized) struct IntegrationTests {
    /// `.build/<config>/halltone-linux`: `swift test` builds the whole package first.
    static var binary: URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return packageRoot.appendingPathComponent(".build/debug/halltone-linux")
    }

    final class Running {
        let process = Process()
        let port: UInt16
        let output = Pipe()
        let configDir: String

        init(extraArgs: [String] = [], code: String = "4321") throws {
            port = UInt16.random(in: 30_000...60_000)
            configDir = NSTemporaryDirectory() + "halltone-it-\(UUID().uuidString)"
            process.executableURL = IntegrationTests.binary
            process.arguments = ["--source", "tone", "--no-advertise", "--code", code, "--name", "Test Rig",
                                 "--port", String(port), "--config", configDir + "/config.json"] + extraArgs
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        /// Subscribes (retrying while the process starts up) and returns the client once ACKed.
        func connect(code: UInt32 = 4321) -> (TestClient, subscribeAck: (CodecID, UInt16, String))? {
            let c = TestClient(port: port)
            for _ in 0..<25 {
                c.send(.subscribe(pairingCode: code, deviceName: "Phone", deviceID: "it-phone"))
                if let ack: (CodecID, UInt16, String) = c.receive(timeout: 0.4, until: { p in
                    if case .subscribeAck(let codec, _, _, let frame, let name) = p.message { return (codec, frame, name) }
                    return nil
                }) { return (c, ack) }
            }
            return nil
        }

        func terminate() {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(atPath: configDir)
        }
    }

    @Test func streamsATonePairedWithTheCodeInGameMode() throws {
        #expect(FileManager.default.isExecutableFile(atPath: Self.binary.path), "build the package first: \(Self.binary.path)")
        let run = try Running()
        defer { run.terminate() }
        let (client, ack) = try #require(run.connect())
        #expect(ack.0 == .pcm16)
        #expect(ack.1 == 120) // Game mode: 2.5 ms frames
        #expect(ack.2 == "Test Rig")

        let decoder = PCM16Decoder(frameSamples: 120)
        var pcm = [Float](repeating: 0, count: 240)
        var positions: [UInt64] = []
        var left: [Float] = []
        var statusSeen = false
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, positions.count < 400 {
            guard let p = client.receive(timeout: 0.5) else { continue }
            switch p.message {
            case .audio(let pos, _, let payload):
                positions.append(pos)
                payload.withUnsafeBytes { raw in
                    if decoder.decode(raw, into: &pcm) { for i in 0..<120 { left.append(pcm[2 * i]) } }
                }
            case .status(let flags):
                statusSeen = true
                #expect(!flags.contains(.controlsAvailable)) // no media keys on Linux
            default: break
            }
        }
        #expect(positions.count >= 400, "only \(positions.count) packets in 4 s")
        for (a, b) in zip(positions, positions.dropFirst()) {
            #expect(b == a + 120, "gap \(a) → \(b)")
        }
        #expect(statusSeen)

        // The tone is 440 Hz (plus a click once a second): count upward zero crossings in the
        // first 0.5 s of audio, skipping the click.
        let window = Array(left.prefix(24_000))
        var crossings = 0
        for i in 1..<window.count where window[i - 1] < 0 && window[i] >= 0 { crossings += 1 }
        let hz = Double(crossings) / (Double(window.count) / 48_000)
        #expect(abs(hz - 440) < 25, "measured \(hz) Hz")
        let peak = left.map { abs($0) }.max() ?? 0
        #expect(peak > 0.2 && peak < 1.0, "peak \(peak)")
    }

    @Test func wrongCodeIsRefusedAndKeepaliveAndByeWork() throws {
        let run = try Running()
        defer { run.terminate() }
        // Wait until the process answers: first with the right code.
        let (good, _) = try #require(run.connect())
        let bad = TestClient(port: run.port)
        bad.send(.subscribe(pairingCode: 1111, deviceName: "Intruder", deviceID: nil))
        let nak: UInt8? = bad.receive(until: { p in if case .subscribeNak(let r) = p.message { return r } else { return nil } })
        #expect(nak == NakReason.badPairingCode.rawValue)

        good.send(.keepalive(lastSeqReceived: 1, lossPermille: 0, bufferMs: 40))
        good.send(.bye)
        // After BYE the audio stops (nothing more than what was in flight).
        _ = good.receive(timeout: 0.3)
        var late = 0
        let end = Date().addingTimeInterval(1)
        while Date() < end { if let p = good.receive(timeout: 0.1), case .audio = p.message { late += 1 } }
        #expect(late < 20, "audio kept flowing after BYE: \(late) packets")
    }

    @Test func sigtermSaysByeToSubscribers() throws {
        let run = try Running()
        defer { run.terminate() }
        let (client, _) = try #require(run.connect())
        kill(run.process.processIdentifier, SIGTERM)
        let sawBye: Bool? = client.receive(timeout: 3, until: { p in if case .bye = p.message { return true } else { return nil } })
        #expect(sawBye == true)
        run.process.waitUntilExit()
        #expect(run.process.terminationStatus == 0)
    }

    @Test func opusModeAnnouncesItself() throws {
        let run = try Running(extraArgs: ["--codec", "opus"])
        defer { run.terminate() }
        let (_, ack) = try #require(run.connect())
        #expect(ack.0 == .opus)
        #expect(ack.1 == UInt16(Constants.opusFrameSamples))
    }

    @Test func firstRunPrintsAndSavesTheGeneratedCode() throws {
        let dir = NSTemporaryDirectory() + "halltone-first-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = Process()
        p.executableURL = Self.binary
        let port = UInt16.random(in: 30_000...60_000)
        p.arguments = ["--source", "tone", "--no-advertise", "--port", String(port), "--config", dir + "/c.json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer { if p.isRunning { p.terminate(); p.waitUntilExit() } }
        // The banner is printed before the sender starts listening.
        var text = ""
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !text.contains("udp/") {
            text += String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        }
        let digits = text.components(separatedBy: "pairing code: ").dropFirst().first?.prefix(4)
        let printed = try #require(digits.flatMap { UInt32($0) })
        #expect((1000...9999).contains(printed))
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/c.json"))) as? [String: Any]
        #expect(saved?["pairingCode"] as? Int == Int(printed))
    }

    @Test func helpAndBadFlagsExitCleanly() throws {
        let p = Process()
        p.executableURL = Self.binary
        p.arguments = ["--help"]
        p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let q = Process()
        q.executableURL = Self.binary
        q.arguments = ["--no-such-flag"]
        q.standardError = Pipe()
        try q.run(); q.waitUntilExit()
        #expect(q.terminationStatus == 2)
    }
}
