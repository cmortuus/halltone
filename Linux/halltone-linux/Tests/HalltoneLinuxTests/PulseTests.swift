import Testing
import Foundation
import HalltoneCore

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
}
