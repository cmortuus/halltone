import Foundation
import HalltoneCore
import HalltoneDialogEval
import HalltoneSenderCore

/// Test input (`--source wav:<file>`): plays a WAV file once in real time (any rate or channel
/// count, converted to 48 kHz stereo), then goes quiet. Feeds the dialog tap like the real capture.
public final class WavSource: AudioSource {
    public var dataAvailable: DispatchSemaphore?
    public private(set) var sampleRate: Double?
    private let samples: [Float]
    private let blockFrames: Int
    private let tap: DialogTap?
    private let lock = NSLock()
    private var running = false

    public init(path: String, blockFrames: Int = 120, tap: DialogTap? = nil) throws {
        samples = WAV.toStereo48k(try WAV.read(path: path))
        self.blockFrames = blockFrames
        self.tap = tap
    }

    public var durationSeconds: Double { Double(samples.count / 2) / 48_000 }

    public func start(into ring: RingBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        sampleRate = Constants.sampleRate
        let t = Thread { [self] in
            let total = samples.count / 2
            let start = Date()
            var produced = 0
            while isRunning, produced < total {
                let target = min(total, Int(Date().timeIntervalSince(start) * 48_000))
                while produced < target, isRunning {
                    let n = min(blockFrames, total - produced)
                    samples.withUnsafeBufferPointer { p in
                        let base = p.baseAddress! + 2 * produced
                        _ = ring.write(base, count: 2 * n)
                        tap?.push(base, count: 2 * n)
                    }
                    produced += n
                    dataAvailable?.signal()
                }
                usleep(1_000)
            }
        }
        t.name = "com.halltone.wav"
        t.start()
    }

    public func stop() { lock.lock(); running = false; lock.unlock() }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    public func makeResampler() -> AudioResampler? { nil }
}
