import Foundation
import HalltoneCore
import HalltoneSenderCore
#if canImport(os)
import os
#endif

private let log = Logger(subsystem: Constants.logSubsystem, category: "DialogApp")

/// Records one application's own playback stream (a PulseAudio *sink input*) for the dialog
/// detector, so voice chat or a browser doesn't count as game dialog. The streamed audio is still
/// the whole monitor.
///
/// The PulseAudio *simple* API cannot record a single sink input: that needs
/// `pa_stream_set_monitor_stream`, which only the asynchronous API has. `parec --monitor-stream=N`
/// (package pulseaudio-utils, which the sender already needs for `pactl`) is exactly that call, so
/// this runs `parec` and reads its raw float32 stereo output. A supervisor looks the application up
/// with `pactl -f json list sink-inputs` once a second, and (re)starts or stops `parec` as the
/// stream appears, changes or goes away; while there is no stream the tap hears paced silence.
public final class AppStreamCapture {
    private let app: String
    private let tap: DialogTap
    private let lock = NSLock()
    private var running = false
    private var generation = 0
    private var process: Process?
    private var currentIndex: Int?
    private var _refusedBecausePlayer = false
    /// Keys naming streams that must never be analyzed (the player the dialog pause controls): its
    /// own speech would otherwise start a pause/resume loop. Empty for the Mac target.
    private let excluding: () -> [String]

    public init(app: String, tap: DialogTap, excluding: @escaping () -> [String] = { [] }) {
        self.app = app; self.tap = tap; self.excluding = excluding
    }

    /// `sourceApp` names the stream of the player being paused, so nothing is analyzed.
    public var refusedBecausePlayer: Bool { lock.lock(); defer { lock.unlock() }; return _refusedBecausePlayer }

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        generation += 1
        let mine = generation
        lock.unlock()
        let t = Thread { [self] in supervise(mine) }
        t.name = "com.halltone.dialog.app"
        t.start()
    }

    public func stop() {
        lock.lock(); running = false; let p = process; process = nil; currentIndex = nil; lock.unlock()
        p?.terminate()
    }

    private func isRunning(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return running && generation == gen }

    private func supervise(_ gen: Int) {
        guard let pactl = MacLocator.find("pactl"), let parec = MacLocator.find("parec") else {
            log.error("dialogPause.sourceApp needs pactl and parec (package pulseaudio-utils); not analyzing \(self.app, privacy: .public)")
            return
        }
        var warnedMissing = false
        while isRunning(gen) {
            let result = Self.sinkInputMatch(app: app, pactl: pactl, excluding: excluding())
            let index = result?.index
            lock.lock()
            let wasRefused = _refusedBecausePlayer
            _refusedBecausePlayer = result?.excluded == true
            lock.unlock()
            if result?.excluded == true, !wasRefused {
                log.error("dialogPause.sourceApp \"\(self.app, privacy: .public)\" is the stream of the player that gets paused: NOT analyzing it (its own speech would pause and resume it in a loop). Set sourceApp to the game's name (`halltone-linux apps`).")
            }
            lock.lock()
            let alive = process?.isRunning == true
            let changed = index != currentIndex || (index != nil && !alive)
            lock.unlock()
            if changed {
                stopProcess()
                if let index {
                    warnedMissing = false
                    launch(parec: parec, index: index)
                } else if !warnedMissing {
                    warnedMissing = true
                    log.notice("no playback stream from \"\(self.app, privacy: .public)\" yet; dialog analysis hears silence until it plays")
                }
                lock.lock(); currentIndex = index; lock.unlock()
            }
            Thread.sleep(forTimeInterval: 1)
        }
        if !isRunning(gen) { stopProcess() }
    }

    private func stopProcess() {
        lock.lock(); let p = process; process = nil; lock.unlock()
        p?.terminate()
    }

    private func launch(parec: String, index: Int) {
        let started: Spawn.Started
        do {
            started = try Spawn.start(parec, ["--monitor-stream=\(index)", "--format=float32le", "--rate=48000", "--channels=2",
                                              "--raw", "--latency-msec=20", "--client-name=halltone-dialog"],
                                      captureStdout: true, captureStderr: false)
        } catch {
            log.error("can't start parec: \(error.localizedDescription, privacy: .public)")
            return
        }
        let p = started.process
        guard let fd = started.stdout else { return }
        lock.lock(); process = p; lock.unlock()
        log.notice("analyzing \"\(self.app, privacy: .public)\" (sink input \(index)) for dialog")
        let tap = self.tap
        let t = Thread {
            var carry = Data()
            // Ends at EOF (stopProcess terminates parec) and closes the descriptor; the check is a
            // backstop for a parec that lingers after it was replaced.
            Spawn.readChunks(fd, shouldStop: { [weak self] in
                guard let self else { return true }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.process !== p && !p.isRunning
            }) { d in
                carry.append(d)
                let usable = carry.count - carry.count % 8   // whole stereo float frames
                if usable > 0 {
                    var floats = [Float](repeating: 0, count: usable / 4)
                    floats.withUnsafeMutableBytes { dst in
                        carry.withUnsafeBytes { src in dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<usable])) }
                    }
                    floats.withUnsafeBufferPointer { tap.push($0.baseAddress!, count: floats.count) }
                    carry.removeFirst(usable)
                }
            }
        }
        t.name = "com.halltone.dialog.app.read"
        t.start()
    }

    // MARK: -

    static func sinkInputMatch(app: String, pactl: String, excluding: [String]) -> (index: Int?, excluded: Bool)? {
        guard let data = listSinkInputsJSON(pactl: pactl) else { return nil }
        return matchResult(json: data, app: app, excluding: excluding)
    }

    static func listSinkInputsJSON(pactl: String) -> Data? {
        guard let r = CommandRunner.run(pactl, ["-f", "json", "list", "sink-inputs"], timeout: 5), r.status == 0 else { return nil }
        let data = r.stdoutData
        return data
    }

    /// The sink input to analyze: those whose `application.name`, `application.process.binary` or
    /// `media.name` equal `app` (case-insensitive) win over ones that merely contain it; playing
    /// (not corked) ones win over paused ones; then the lowest index.
    public static func match(json: Data, app: String) -> Int? {
        matchResult(json: json, app: app, excluding: [])?.index
    }

    /// `match` that skips streams belonging to a controlled player (`PlayerStreamMap`). `excluded`
    /// is true when the app would have matched but every match is the player's own stream.
    public static func matchResult(json: Data, app: String, excluding: [String]) -> (index: Int?, excluded: Bool)? {
        guard let list = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] else { return nil }
        let want = app.lowercased()
        var best: (score: Int, index: Int)?
        var sawExcluded = false
        for entry in list {
            guard let index = entry["index"] as? Int else { continue }
            let names = names(of: entry)
            var score = 0
            if names.contains(want) { score = 2 } else if names.contains(where: { $0.contains(want) }) { score = 1 }
            guard score > 0 else { continue }
            if PlayerStreamMap.isExcluded(names: names, keys: excluding) { sawExcluded = true; continue }
            if (entry["corked"] as? Bool) != true { score += 10 }
            if best == nil || score > best!.score || (score == best!.score && index < best!.index) { best = (score, index) }
        }
        return (best?.index, best == nil && sawExcluded)
    }

    static func names(of entry: [String: Any]) -> [String] {
        let props = entry["properties"] as? [String: Any] ?? [:]
        return ["application.name", "application.process.binary", "media.name"].compactMap { (props[$0] as? String)?.lowercased() }
    }

    /// One playback stream, for `halltone-linux apps`.
    public struct SinkInput: Equatable {
        public var index: Int
        public var name: String
        public var binary: String
        public var media: String
        public var corked: Bool
    }

    public static func sinkInputs(json: Data) -> [SinkInput] {
        guard let list = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] else { return [] }
        return list.compactMap { e in
            guard let index = e["index"] as? Int else { return nil }
            let p = e["properties"] as? [String: Any] ?? [:]
            return SinkInput(index: index, name: p["application.name"] as? String ?? "", binary: p["application.process.binary"] as? String ?? "",
                             media: p["media.name"] as? String ?? "", corked: (e["corked"] as? Bool) == true)
        }
    }
}
