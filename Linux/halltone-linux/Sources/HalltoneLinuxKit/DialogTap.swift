import Foundation
import HalltoneCore
import HalltoneDialog

/// A monotonic clock in seconds.
func monotonicNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// Feeds `DialogDetector` from a copy of the captured audio, on its own thread, so detection can
/// never delay capture or streaming.
///
/// The capture thread calls `push` (a flag check, a lock-free ring write and a semaphore signal;
/// when the ring is full the copy is dropped, never waited for). The detector thread drains the
/// ring. While nothing arrives (a suspended sink, a stopped game, a per-app stream with nothing
/// playing) it feeds paced silence, so a dialog still ends instead of staying open forever.
public final class DialogTap {
    private let ring = RingBuffer(capacity: 48_000 * 2 * 4)   // 4 s of stereo float
    private let wake = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _enabled = false
    private var needsReset = false
    private var running = false
    private var thread: Thread?
    private let detector: DialogDetector

    /// Called on the detector thread for each event.
    public var onEvent: ((DialogEvent) -> Void)?
    /// Called on the detector thread after each chunk with `DialogDetector.msSinceSpeech`.
    public var onChunk: ((Int) -> Void)?

    public init(config: DialogConfig = DialogConfig()) {
        detector = DialogDetector(config: config)
    }

    public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return _enabled }

    /// Turning it on starts from a clean detector; turning it off stops all work.
    public func setEnabled(_ on: Bool) {
        lock.lock()
        if on && !_enabled { needsReset = true }
        _enabled = on
        lock.unlock()
        wake.signal()
    }

    /// From the capture thread: interleaved stereo float, `count` samples.
    public func push(_ samples: UnsafePointer<Float>, count: Int) {
        lock.lock(); let on = _enabled; lock.unlock()
        guard on else { return }
        _ = ring.write(samples, count: count)
        wake.signal()
    }

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        let t = Thread { [self] in run() }
        t.name = "com.halltone.dialog"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    public func stop() {
        lock.lock(); running = false; lock.unlock()
        wake.signal()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func run() {
        let chunkFrames = 4_800
        var buf = [Float](repeating: 0, count: chunkFrames * 2)
        let silence = [Float](repeating: 0, count: 48_000 * 2)
        var lastFed = monotonicNow()
        var lastData = lastFed
        while isRunning {
            _ = wake.wait(timeout: .now() + 0.05)
            lock.lock(); let on = _enabled; let reset = needsReset; needsReset = false; lock.unlock()
            if !on {
                _ = ring.skip(ring.availableToRead)
                continue
            }
            if reset {
                _ = ring.skip(ring.availableToRead)
                detector.reset()
                lastFed = monotonicNow(); lastData = lastFed
            }
            var fed = false
            while true {
                let avail = min(ring.availableToRead, buf.count) & ~1
                if avail == 0 { break }
                let n = buf.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: avail) }
                if n <= 0 { break }
                feed(buf, frames: n / 2)
                fed = true
            }
            let now = monotonicNow()
            if fed {
                lastFed = now; lastData = now
            } else if now - lastData > 0.1 {
                // Idle: keep the detector's clock moving in real time.
                let frames = min(Int((now - lastFed) * 48_000), silence.count / 2)
                if frames >= 480 {
                    feed(silence, frames: frames)
                    lastFed = now
                }
            }
        }
    }

    private func feed(_ samples: [Float], frames: Int) {
        samples.withUnsafeBufferPointer { p in
            detector.process(p.baseAddress!, frames: frames) { event in onEvent?(event) }
        }
        onChunk?(detector.msSinceSpeech)
    }
}
