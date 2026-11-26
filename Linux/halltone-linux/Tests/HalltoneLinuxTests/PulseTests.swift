import Testing
import Foundation
import HalltoneCore
import HalltoneDialogEval

/// Real PulseAudio capture, only where CI (or a developer) has a server with a null sink and sets
/// HALLTONE_PULSE_TEST=1: the sender listens to the default sink's monitor, and keeps doing so
/// after the default sink is switched.
@Suite(.serialized) struct PulseTests {
    static let enabled = ProcessInfo.processInfo.environment["HALLTONE_PULSE_TEST"] == "1"

    @discardableResult
    static func sh(_ command: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    /// Plays white noise into `sink` until the returned process is terminated.
    static func noise(into sink: String) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exec pacat --format=s16le --rate=48000 --channels=2 --device=\(sink) < /dev/urandom"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// Loudest sample in packets arriving over `seconds`.
    static func peak(of client: TestClient, seconds: TimeInterval, frameSamples: Int = 120) -> Float {
        let decoder = PCM16Decoder(frameSamples: frameSamples)
        var pcm = [Float](repeating: 0, count: frameSamples * 2)
        var peak: Float = 0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            guard let p = client.receive(timeout: 0.2), case .audio(_, _, let payload) = p.message else { continue }
            payload.withUnsafeBytes { raw in
                if decoder.decode(raw, into: &pcm) { peak = max(peak, pcm.map { abs($0) }.max() ?? 0) }
            }
        }
        return peak
    }

    @Test(.enabled(if: PulseTests.enabled)) func capturesTheDefaultMonitorAndFollowsADefaultSinkChange() throws {
        let run = try IntegrationTests.Running(extraArgs: ["--source", "pulse"])
        defer { run.terminate() }
        let (client, ack) = try #require(run.connect())
        #expect(ack.1 == 120)

        // Silence first: nothing is playing, and the stream is paced silence, not a gap.
        let quiet = Self.peak(of: client, seconds: 1)
        #expect(quiet < 0.001, "heard \(quiet) with nothing playing")

        let first = try Self.noise(into: "ci")
        defer { first.terminate() }
        let loud = Self.peak(of: client, seconds: 2)
        #expect(loud > 0.2, "noise on the default sink didn't arrive (peak \(loud))")

        // Switch the default sink; the old noise stops and new noise plays on the new sink.
        #expect(Self.sh("pactl load-module module-null-sink sink_name=ci2") == 0)
        #expect(Self.sh("pactl set-default-sink ci2") == 0)
        first.terminate()
        let second = try Self.noise(into: "ci2")
        defer { second.terminate() }
        var followed: Float = 0
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, followed < 0.2 { followed = Self.peak(of: client, seconds: 1) }
        #expect(followed > 0.2, "capture didn't follow the default sink change (peak \(followed))")
    }

    /// Hammers default-sink switches: capture must keep flowing after every one.
    @Test(.enabled(if: PulseTests.enabled)) func survivesRepeatedDefaultSinkSwitches() throws {
        let run = try IntegrationTests.Running(extraArgs: ["--source", "pulse"])
        defer { run.terminate() }
        let (client, _) = try #require(run.connect())
        _ = Self.sh("pactl load-module module-null-sink sink_name=ci2")
        let noiseA = try Self.noise(into: "ci")
        let noiseB = try Self.noise(into: "ci2")
        defer { noiseA.terminate(); noiseB.terminate() }
        var lastPos: UInt64?
        for round in 0..<8 {
            let sink = round % 2 == 0 ? "ci2" : "ci"
            #expect(Self.sh("pactl set-default-sink \(sink)") == 0)
            var heard: Float = 0
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, heard < 0.2 { heard = Self.peak(of: client, seconds: 0.5) }
            #expect(heard > 0.2, "no audio after switching to \(sink) (round \(round))")
        }
        // The stream stayed continuous (sample positions only ever advance by whole frames).
        var positions: [UInt64] = []
        let end = Date().addingTimeInterval(0.5)
        while Date() < end {
            if let p = client.receive(timeout: 0.1), case .audio(let pos, _, _) = p.message { positions.append(pos) }
        }
        for (a, b) in zip(positions, positions.dropFirst()) { #expect(b == a + 120); lastPos = b }
        #expect(lastPos != nil)
    }

    // MARK: sourceApp (per-application analysis through parec --monitor-stream)

    /// Plays `path` into the default sink as an application called `app`; returns when it finished.
    static func play(_ path: String, as app: String) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exec paplay --client-name='\(app)' --device=ci '\(path)'"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// Dialog is spoken by "Game" while "Game" is the analyzed application: the Mac is paused and resumed.
    @Test(.enabled(if: PulseTests.enabled && SpeechSynth.isAvailable))
    func dialogFromTheAnalyzedApplicationPausesTheMac() throws {
        let dir = DialogPauseEndToEndTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fx = try #require(try DialogPauseEndToEndTests.fixture(dir: dir))
        let mac = FakeMac()
        defer { mac.stop() }
        let run = try DialogPauseEndToEndTests.Run(args: ["--source", "tone", "--dialog-pause", "--dialog-app", "Game",
                                                          "--dialog-mac", "127.0.0.1:\(mac.port)", "--dialog-code", "7777"], dir: dir)
        defer { run.stop() }
        Thread.sleep(forTimeInterval: 1)
        let player = try Self.play(fx.path, as: "Game")
        defer { player.terminate() }
        player.waitUntilExit()
        Thread.sleep(forTimeInterval: 4)   // the end of the dialog and the resume delay
        #expect(mac.requests.map(\.command) == [.pauseForPeer, .resumeForPeer], "got \(mac.requests.map(\.command)); log:\n\(run.log)")
    }

    /// The same dialog from another application ("VoiceChat") is not analyzed: nothing is sent.
    @Test(.enabled(if: PulseTests.enabled && SpeechSynth.isAvailable))
    func dialogFromAnotherApplicationIsIgnored() throws {
        let dir = DialogPauseEndToEndTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fx = try #require(try DialogPauseEndToEndTests.fixture(dir: dir))
        let mac = FakeMac()
        defer { mac.stop() }
        let run = try DialogPauseEndToEndTests.Run(args: ["--source", "tone", "--dialog-pause", "--dialog-app", "Game",
                                                          "--dialog-mac", "127.0.0.1:\(mac.port)", "--dialog-code", "7777"], dir: dir)
        defer { run.stop() }
        Thread.sleep(forTimeInterval: 1)
        let player = try Self.play(fx.path, as: "VoiceChat")
        defer { player.terminate() }
        player.waitUntilExit()
        Thread.sleep(forTimeInterval: 3)
        #expect(mac.requests.isEmpty, "voice chat triggered \(mac.requests.map(\.command)); log:\n\(run.log)")
    }
}
