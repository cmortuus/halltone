import Testing
import Foundation
import HalltoneCore
import HalltoneDialogEval
@testable import HalltoneLinuxKit

/// `dialogPause.target = "local"` against the real executable. The game's dialog is a WAV
/// (`--source wav:`, or a PulseAudio stream called "Game"), the video is a fake MPRIS player on a
/// private D-Bus session bus, and "video speech" is a second audio stream from that player that is
/// audible exactly while it plays: the feedback loop this feature must not fall into.
///
/// CI: `HALLTONE_DBUS_TEST=1` (inside dbus-run-session) for the WAV test, plus `HALLTONE_PULSE_TEST=1`
/// and `PULSE_SERVER` for the ones with real audio streams. The refusal test needs neither.
@Suite(.serialized, .timeLimit(.minutes(3))) struct LocalDialogIntegrationTests {
    static let dbus = ProcessInfo.processInfo.environment["HALLTONE_DBUS_TEST"] == "1"
    static let pulse = ProcessInfo.processInfo.environment["HALLTONE_PULSE_TEST"] == "1"
    static let bus = "org.mpris.MediaPlayer2.fakevideo"

    /// Records every change of the fake player's PlaybackStatus, with the time it was seen.
    final class StatusWatcher {
        private let lock = NSLock()
        private var running = true
        private(set) var changes: [(status: MPRISStatus, at: Double)] = []
        private var last: MPRISStatus?
        init(player: String = "fakevideo") {
            let backend = BusctlBackend(timeout: 2)
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock(); let on = running; lock.unlock()
                    if !on { return }
                    if let s = (try? backend.players())?.first(where: { $0.shortName == player })?.status {
                        lock.lock()
                        if s != last { changes.append((s, Date().timeIntervalSinceReferenceDate)); last = s }
                        lock.unlock()
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
        func stop() { lock.lock(); running = false; lock.unlock() }
        /// Statuses after the first one: what the player was made to do.
        var transitions: [MPRISStatus] { lock.lock(); defer { lock.unlock() }; return changes.dropFirst().map(\.status) }
        func time(ofTransition i: Int) -> Double? { lock.lock(); defer { lock.unlock() }; return changes.dropFirst().dropFirst(i).first?.at }
        var current: MPRISStatus? { lock.lock(); defer { lock.unlock() }; return last }
    }

    /// Plays `path` as application `client` into sink `ci`, again and again while `shouldPlay()`.
    final class LoopingStream {
        private let lock = NSLock()
        private var running = true
        private var process: Process?
        init(path: String, client: String, shouldPlay: @escaping () -> Bool) {
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock(); let on = running; lock.unlock()
                    if !on { return }
                    if shouldPlay() {
                        if process?.isRunning != true { process = try? PulseTests.play(path, as: client) }
                    } else if let p = process, p.isRunning {
                        p.terminate(); process = nil
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
        func stop() { lock.lock(); running = false; let p = process; lock.unlock(); p?.terminate() }
    }

    static let videoLine = "Welcome back to the channel everyone. Today we are going to look at how to build the best possible gaming computer on a budget, step by step."

    static func videoSpeech(dir: String) throws -> String? {
        guard let mix = makeDemoMix(lines: [videoLine, videoLine], gaps: [0.3], leadIn: 0.2, tail: 0.2, musicGain: 0, speechOverMusicDB: 9) else { return nil }
        let path = dir + "/video.wav"
        try WAV.write16(path: path, sampleRate: 48_000, channels: 2, samples: mix.samples)
        return path
    }

    // MARK: no pulse, no bus: configuration

    @Test func withoutASourceAppTheLocalTargetRefusesToStartAndSaysWhy() throws {
        let dir = DialogPauseEndToEndTests.tempDir()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = Process()
        p.executableURL = IntegrationTests.binary
        p.arguments = ["--config", dir + "/c.json", "--code", "4321", "--no-advertise", "--dialog-pause", "--dialog-target", "local",
                       "--control-socket", dir + "/s"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        try p.run()
        IntegrationTests.wait(p, seconds: 8)
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 1, "\(text)")
        #expect(text.contains("sourceApp") && text.contains("halltone-linux apps"), "\(text)")
    }

    // MARK: WAV "game dialog" + a fake MPRIS player

    @Test(.enabled(if: LocalDialogIntegrationTests.dbus && SpeechSynth.isAvailable, "needs dbus-run-session and espeak-ng"))
    func gameDialogPausesTheLocalPlayerAndResumesItAfterwards() throws {
        let dir = DialogPauseEndToEndTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fx = try #require(try DialogPauseEndToEndTests.fixture(dir: dir))
        let player = try DBusIntegrationTests.FakePlayer("fakevideo", "Playing", identity: "Fake Video"); defer { player.stop() }
        let watcher = StatusWatcher(); defer { watcher.stop() }
        #expect(waitUntil(5) { watcher.current == .playing })
        let run = try DialogPauseEndToEndTests.Run(args: ["--source", "wav:" + fx.path, "--dialog-pause", "--dialog-target", "local",
                                                          "--media-player", "fakevideo"], dir: dir)
        defer { run.stop() }
        let t0 = try #require(run.listen(for: fx.speechEnd + 6))
        if ProcessInfo.processInfo.environment["HALLTONE_SHOW_LOG"] != nil { print(run.log) }
        #expect(watcher.transitions == [.paused, .playing], "got \(watcher.transitions); log:\n\(run.log)")
        guard watcher.transitions.count == 2 else { return }
        let pauseAt = watcher.time(ofTransition: 0)! - t0, resumeAt = watcher.time(ofTransition: 1)! - t0
        #expect(pauseAt > fx.speechStart + 0.3 && pauseAt < fx.speechEnd - 0.3, "pause at \(pauseAt), speech \(fx.speechStart)…\(fx.speechEnd)")
        #expect(resumeAt > fx.speechEnd + 1.0 && resumeAt < fx.speechEnd + 3.5, "resume at \(resumeAt), speech ended \(fx.speechEnd)")
        // The kill switch and `status` report the target.
        var r = try DialogPauseEndToEndTests.dialogCommand("status", socket: run.socket)
        #expect(r.status == 0 && r.output.contains("target: local (MPRIS)") && r.output.contains("fakevideo"), "\(r)")
        r = try DialogPauseEndToEndTests.dialogCommand("off", socket: run.socket)
        #expect(r.output.contains("ok: dialog pause off"), "\(r)")
    }

    // MARK: real audio streams: a "Game" stream and "video speech" from the player

    /// The game's dialog pauses the player; the player's own speech, audible exactly while it
    /// plays and loud enough to count as dialog, never pauses it again.
    @Test(.enabled(if: LocalDialogIntegrationTests.dbus && LocalDialogIntegrationTests.pulse && SpeechSynth.isAvailable, "needs dbus, pulse and espeak-ng"))
    func theVideosOwnSpeechDoesNotStartAPauseLoop() throws {
        let dir = DialogPauseEndToEndTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fx = try #require(try DialogPauseEndToEndTests.fixture(dir: dir))
        let video = try #require(try Self.videoSpeech(dir: dir))
        let player = try DBusIntegrationTests.FakePlayer("fakevideo", "Playing", identity: "Fake Video"); defer { player.stop() }
        let watcher = StatusWatcher(); defer { watcher.stop() }
        #expect(waitUntil(5) { watcher.current == .playing })
        let run = try DialogPauseEndToEndTests.Run(args: ["--source", "tone", "--dialog-pause", "--dialog-target", "local",
                                                          "--dialog-app", "Game", "--media-player", "fakevideo"], dir: dir)
        defer { run.stop() }
        let speech = LoopingStream(path: video, client: "Fake Video") { watcher.current == .playing }
        defer { speech.stop() }
        Thread.sleep(forTimeInterval: 2)
        // No pause from the video's speech alone, before the game says anything.
        #expect(watcher.transitions.isEmpty, "paused by the video's own speech; log:\n\(run.log)")
        let game = try PulseTests.play(fx.path, as: "Game")
        defer { game.terminate() }
        game.waitUntilExit()
        Thread.sleep(forTimeInterval: 5)       // the resume, then plenty of video speech afterwards
        if ProcessInfo.processInfo.environment["HALLTONE_SHOW_LOG"] != nil { print(run.log) }
        #expect(watcher.transitions == [.paused, .playing], "got \(watcher.transitions); log:\n\(run.log)")
        #expect(watcher.current == .playing)
    }

    /// `sourceApp` names the video player's own stream: it is refused, so its speech can't pause it.
    @Test(.enabled(if: LocalDialogIntegrationTests.dbus && LocalDialogIntegrationTests.pulse && SpeechSynth.isAvailable, "needs dbus, pulse and espeak-ng"))
    func aSourceAppThatIsTheControlledPlayerIsNotAnalyzed() throws {
        let dir = DialogPauseEndToEndTests.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let video = try #require(try Self.videoSpeech(dir: dir))
        let player = try DBusIntegrationTests.FakePlayer("fakevideo", "Playing", identity: "Fake Video"); defer { player.stop() }
        let watcher = StatusWatcher(); defer { watcher.stop() }
        #expect(waitUntil(5) { watcher.current == .playing })
        let run = try DialogPauseEndToEndTests.Run(args: ["--source", "tone", "--dialog-pause", "--dialog-target", "local",
                                                          "--dialog-app", "Fake Video", "--media-player", "fakevideo"], dir: dir)
        defer { run.stop() }
        #expect(DialogPauseEndToEndTests.waitForSocket(run.socket))
        let speech = LoopingStream(path: video, client: "Fake Video") { watcher.current == .playing }
        defer { speech.stop() }
        Thread.sleep(forTimeInterval: 6)
        #expect(watcher.transitions.isEmpty, "the player's own speech paused it; log:\n\(run.log)")
        let r = try DialogPauseEndToEndTests.dialogCommand("status", socket: run.socket)
        #expect(r.output.contains("NOT ANALYZING"), "\(r)")
        // `halltone-linux apps` marks the same stream.
        var apps = try DBusIntegrationTests.cli(["apps", "--media-player", "fakevideo"])
        for _ in 0..<10 where !apps.output.contains("never analyzed") {   // the stream may be between two loops
            Thread.sleep(forTimeInterval: 0.3)
            apps = try DBusIntegrationTests.cli(["apps", "--media-player", "fakevideo"])
        }
        #expect(apps.status == 0 && apps.output.contains("Fake Video") && apps.output.contains("never analyzed"), "\(apps)")
    }
}
