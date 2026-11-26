import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import HalltoneDialog
import HalltoneDialogEval

private func detect(_ samples: [Float], chunk: Int = 480, config: DialogConfig = DialogConfig()) -> [DialogEvent] {
    let d = DialogDetector(config: config)
    var events: [DialogEvent] = []
    let frames = samples.count / 2
    samples.withUnsafeBufferPointer { buf in
        var pos = 0
        while pos < frames {
            let n = min(chunk, frames - pos)
            events += d.process(buf.baseAddress! + 2 * pos, frames: n)
            pos += n
        }
    }
    return events
}

final class NonSpeechTests: XCTestCase {
    func testSilenceProducesNoEvents() {
        XCTAssertEqual(detect([Float](repeating: 0, count: 48_000 * 2 * 10)), [])
    }

    func testSineProducesNoEvents() {
        for hz in [110.0, 440, 1000, 3000] {
            XCTAssertEqual(detect(SyntheticAudio.sine(seconds: 10, hz: hz)), [], "sine \(hz) Hz")
        }
    }

    func testPinkNoiseProducesNoEvents() {
        for amp: Float in [0.02, 0.1, 0.5] {
            XCTAssertEqual(detect(SyntheticAudio.pinkNoise(seconds: 10, amplitude: amp)), [], "pink \(amp)")
        }
    }

    func testWideMusicLikeNoiseProducesNoEvents() {
        for (amp, seed) in [(Float(0.15), UInt64(7)), (0.4, 11), (0.8, 23)] {
            XCTAssertEqual(detect(SyntheticAudio.wideMusic(seconds: 30, amplitude: amp, seed: seed)), [],
                           "music amp \(amp) seed \(seed)")
        }
    }

    func testNonFiniteInputIsHarmless() {
        var x = SyntheticAudio.pinkNoise(seconds: 1, amplitude: 0.1)
        x[100] = .nan; x[101] = .infinity; x[5000] = -.infinity
        XCTAssertEqual(detect(x), [])
        // and the detector still works afterwards
        let d = DialogDetector()
        x.withUnsafeBufferPointer { _ = d.process($0.baseAddress!, frames: x.count / 2) }
        XCTAssertFalse(d.isDialogActive)
    }

    func testChunkingDoesNotChangeResult() throws {
        let x = SyntheticAudio.wideMusic(seconds: 5, amplitude: 0.15)
        XCTAssertEqual(detect(x, chunk: 480), detect(x, chunk: 1))
        guard SpeechSynth.isAvailable, let demo = makeDemoMix(lines: ["The door is locked."], gaps: [1]) else {
            throw XCTSkip("no text-to-speech engine")
        }
        let a = detect(demo.samples, chunk: 480), b = detect(demo.samples, chunk: 777), c = detect(demo.samples, chunk: 1)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
        XCTAssertFalse(a.isEmpty)
    }

    func testResetForgetsEverything() throws {
        guard let demo = makeDemoMix(lines: ["The door is locked. You will need to find the key."], gaps: [1]) else {
            throw XCTSkip("no text-to-speech engine")
        }
        let first = detect(demo.samples)
        let d = DialogDetector()
        var n = 0
        demo.samples.withUnsafeBufferPointer { _ = d.process($0.baseAddress!, frames: 48_000 * 5); n += 1 }
        d.reset()
        XCTAssertFalse(d.isDialogActive)
        var events: [DialogEvent] = []
        demo.samples.withUnsafeBufferPointer { events = d.process($0.baseAddress!, frames: demo.samples.count / 2) }
        XCTAssertEqual(events, first)
    }

    #if canImport(Darwin)
    func testProcessDoesNotAllocate() throws {
        var x = SyntheticAudio.wideMusic(seconds: 6, amplitude: 0.3)
        if let demo = makeDemoMix(lines: ["The door is locked. You will need to find the key."], gaps: [1], leadIn: 1, tail: 2) {
            x = demo.samples   // include real dialog so start/end paths run too
        }
        let d = DialogDetector()
        var sawEvent = 0
        x.withUnsafeBufferPointer { buf in
            let frames = buf.count / 2
            // warm up once so lazy runtime/one-time allocations are out of the way
            d.process(buf.baseAddress!, frames: 4800) { _ in }
            d.reset()
            var before = malloc_statistics_t()
            malloc_zone_statistics(nil, &before)
            var pos = 0
            while pos < frames {
                let n = min(480, frames - pos)
                d.process(buf.baseAddress! + 2 * pos, frames: n) { _ in sawEvent += 1 }
                pos += n
            }
            var after = malloc_statistics_t()
            malloc_zone_statistics(nil, &after)
            XCTAssertEqual(after.blocks_in_use, before.blocks_in_use, "process() allocated")
            XCTAssertEqual(after.size_in_use, before.size_in_use, "process() allocated")
        }
        if SpeechSynth.isAvailable { XCTAssertGreaterThan(sawEvent, 0) }
    }
    #endif

    func testRealtimeBudget() {
        let x = SyntheticAudio.wideMusic(seconds: 30, amplitude: 0.3)
        let d = DialogDetector()
        let frames = x.count / 2
        let t0 = DispatchTime.now().uptimeNanoseconds
        x.withUnsafeBufferPointer { buf in
            var pos = 0
            while pos < frames {
                let n = min(480, frames - pos)
                d.process(buf.baseAddress! + 2 * pos, frames: n) { _ in }
                pos += n
            }
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        let load = seconds / 30
        #if DEBUG
        XCTAssertLessThan(load, 0.25, "debug build: \(load * 100)% of one core")   // unoptimised; release is checked below
        #else
        XCTAssertLessThan(load, 0.02, "\(load * 100)% of one core")
        #endif
    }
}

final class SpeechTests: XCTestCase {
    private static let lines = [
        "The door is locked. You will need to find the key.",
        "Watch out, there are guards on the next floor.",
        "I knew you would come back, it has been a very long time.",
    ]

    /// `speechOverMusicDB`, when given, scales every line by its *active RMS* relative to the music's
    /// RMS, so the level relationship is identical for `say` and `espeak-ng` (their peak-to-RMS
    /// ratios differ by ~7 dB, which made peak-based levels voice-dependent). Otherwise lines are
    /// scaled so the loudest peaks at `speechGain`.
    private func demo(speechGain: Float = 0.5, musicGain: Float, speechOverMusicDB: Double? = nil) throws -> DemoMix {
        guard SpeechSynth.isAvailable else { throw XCTSkip("neither `say` nor `espeak-ng` is installed") }
        return try XCTUnwrap(makeDemoMix(lines: Self.lines, gaps: [4, 5], speechGain: speechGain, musicGain: musicGain,
                                         speechOverMusicDB: speechOverMusicDB))
    }

    private func check(_ mix: DemoMix, minPrecision: Double, file: StaticString = #filePath, line: UInt = #line) {
        let events = detect(mix.samples)
        let starts = events.filter { $0.isStart }, ends = events.filter { !$0.isStart }
        XCTAssertEqual(starts.count, mix.labels.count, "events: \(events)", file: file, line: line)
        XCTAssertEqual(ends.count, mix.labels.count, "events: \(events)", file: file, line: line)
        let r = evaluate(events: events, labels: mix.labels, streamEnd: Double(mix.samples.count / 2) / 48_000)
        XCTAssertGreaterThan(r.recall, 0.9, file: file, line: line)
        XCTAssertGreaterThan(r.precision, minPrecision, file: file, line: line)
        for (s, l) in zip(starts, mix.labels) {
            // started within a quarter second before to ~0.8 s after the speech really begins
            XCTAssertEqual(s.time, l.start, accuracy: 0.8, file: file, line: line)
            XCTAssertLessThan(s.detectedAt - l.start, 1.0, file: file, line: line)
        }
        for (e, l) in zip(ends, mix.labels) {
            // the end reports the last speech frame; it fires ~1.2 s after
            XCTAssertEqual(e.time, l.end, accuracy: 1.2, file: file, line: line)
            XCTAssertEqual(e.detectedAt - e.time, 1.2, accuracy: 0.05, file: file, line: line)
        }
    }

    func testSpeechOverMusic() throws {
        check(try demo(musicGain: 0.15, speechOverMusicDB: 9), minPrecision: 0.75)
    }

    func testSpeechAlone() throws {
        check(try demo(musicGain: 0), minPrecision: 0.75)
    }

    func testQuietSpeechOverLouderMusic() throws {
        // Dialog only 3 dB above (RMS) loud music must still be found: it is centered, the music is wide.
        // This is the detector's working limit, deliberately: center extraction over-subtracts side
        // power (centerSideScale = 2), so dialog at or below the music's level starts to be lost
        // (measured at 0 dB: recall 93-96 %, line ends held open by music; at -3 dB: 64-87 %).
        // Game mixes normally duck music well below dialog. The level is set by RMS so the test
        // means the same thing for `say` and `espeak-ng`.
        check(try demo(musicGain: 0.25, speechOverMusicDB: 3), minPrecision: 0.7)
    }

    func testSpeechBelowLevelGateIsIgnored() throws {
        let mix = try demo(speechGain: 0.0004, musicGain: 0)   // ≈ -68 dBFS peak
        XCTAssertEqual(detect(mix.samples), [])
    }

    func testSpeechPannedHardLeftIsNotCenter() throws {
        var mix = try demo(musicGain: 0)
        // fold the right channel away: a fully left-panned voice is all side + mid, so it is not "centered"
        for i in 0..<mix.samples.count / 2 { mix.samples[2 * i + 1] = 0 }
        let events = detect(mix.samples)
        // Documented limitation rather than a requirement: a hard-panned voice has equal mid and side power,
        // so center extraction removes it.
        XCTAssertTrue(events.isEmpty, "hard-panned speech is expected to be suppressed, got \(events)")
    }
}

final class EvalSupportTests: XCTestCase {
    func testLabelParsing() {
        let l = Labels.parse("# comment\n1.5\t2.5\thello\n\\ 100 200\n0.25\t1.0\tfirst\nbad line\n")
        XCTAssertEqual(l, [Label(start: 0.25, end: 1.0, text: "first"), Label(start: 1.5, end: 2.5, text: "hello")])
    }

    func testWAVRoundTripAndResample() throws {
        let path = NSTemporaryDirectory() + "halltone-test-\(UUID().uuidString).wav"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let x = SyntheticAudio.sine(seconds: 0.5, hz: 440)
        try WAV.write16(path: path, sampleRate: 48_000, channels: 2, samples: x)
        let a = try WAV.read(path: path)
        XCTAssertEqual(a.sampleRate, 48_000); XCTAssertEqual(a.channels, 2); XCTAssertEqual(a.samples.count, x.count)
        XCTAssertEqual(a.samples[1000], x[1000], accuracy: 1e-3)

        var mono = [Float](repeating: 0, count: 22_050)
        for i in 0..<mono.count { mono[i] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(i) / 22_050)) }
        let up = Resampler.resample(mono, from: 22_050, to: 48_000)
        XCTAssertEqual(up.count, 48_000)
        XCTAssertEqual(up[24_000], 0.5 * Float(sin(2 * Double.pi * 440 * 0.5)), accuracy: 0.01)
    }

    func testEvaluateScoresFramesAndLatency() {
        let labels = [Label(start: 1, end: 3)]
        let events: [DialogEvent] = [.started(time: 1.1, detectedAt: 1.35), .ended(time: 3.0, detectedAt: 4.2)]
        let r = evaluate(events: events, labels: labels, streamEnd: 6)
        XCTAssertEqual(r.recall, 0.95, accuracy: 0.01)     // missed the first 0.1 s of 2 s
        XCTAssertEqual(r.precision, 1.0, accuracy: 0.001)
        XCTAssertEqual(EvalReport.median(r.startLatencies) ?? -1, 0.35, accuracy: 1e-9)
        XCTAssertEqual(EvalReport.median(r.endLatencies) ?? -1, 1.2, accuracy: 1e-9)
    }
}
