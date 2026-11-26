import Foundation
import HalltoneCore

/// Synthetic 48 kHz stereo source for testing without the process tap: a sine plus a short
/// click once per second (the click makes latency measurable at the receiver).
public final class ToneSource: AudioSource {
    public private(set) var sampleRate: Double?
    public var dataAvailable: DispatchSemaphore?
    public let frequency: Double
    public let amplitude: Float
    private var thread: Thread?
    private var running = false

    /// Frames written to the ring at a time: 480 by default, 128 to imitate a tap with the
    /// small IO buffer (Game mode; the real tap asks for 64).
    public let blockFrames: Int

    public init(frequency: Double = 440, amplitude: Float = 0.3, blockFrames: Int = 480) {
        self.frequency = frequency
        self.amplitude = amplitude
        self.blockFrames = blockFrames
    }

    public func start(into ring: RingBuffer) throws {
        guard !running else { return }
        running = true
        sampleRate = Constants.sampleRate
        let t = Thread { [self] in
            let rate = Constants.sampleRate
            var phase = 0.0
            var produced: UInt64 = 0
            let block = blockFrames
            var buf = [Float](repeating: 0, count: 2 * block)
            let start = Date()
            while running {
                let target = UInt64(Date().timeIntervalSince(start) * rate)
                while produced < target, running {
                    for i in 0..<block {
                        let samplePos = produced + UInt64(i)
                        var v = Float(sin(phase)) * amplitude
                        phase += 2 * .pi * frequency / rate
                        if phase > 2 * .pi { phase -= 2 * .pi }
                        if samplePos % UInt64(rate) < 48 { v = v + 0.6 } // 1 ms click each second
                        buf[2 * i] = v; buf[2 * i + 1] = v
                    }
                    buf.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 2 * block) }
                    produced += UInt64(block)
                    dataAvailable?.signal()
                }
                usleep(block < 480 ? 500 : 5_000)
            }
        }
        t.qualityOfService = .userInteractive
        t.name = "com.halltone.tone"
        thread = t
        t.start()
    }

    public func stop() {
        running = false
        thread = nil
    }
}
