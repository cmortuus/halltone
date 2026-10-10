#if os(macOS)
import Foundation
import AVFoundation
import HalltoneCore

/// Synthetic 48 kHz stereo source for testing without the process tap: a sine plus a short
/// click once per second (the click makes latency measurable at the receiver).
public final class ToneSource: AudioSource {
    public private(set) var format: AVAudioFormat?
    public var dataAvailable: DispatchSemaphore?
    public let frequency: Double
    public let amplitude: Float
    private var thread: Thread?
    private var running = false

    public init(frequency: Double = 440, amplitude: Float = 0.3) {
        self.frequency = frequency
        self.amplitude = amplitude
    }

    public func start(into ring: RingBuffer) throws {
        guard !running else { return }
        running = true
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Constants.sampleRate, channels: 2, interleaved: true)
        let t = Thread { [self] in
            let rate = Constants.sampleRate
            var phase = 0.0
            var produced: UInt64 = 0
            var buf = [Float](repeating: 0, count: 2 * 480)
            let start = Date()
            while running {
                let target = UInt64(Date().timeIntervalSince(start) * rate)
                while produced < target, running {
                    for i in 0..<480 {
                        let samplePos = produced + UInt64(i)
                        var v = Float(sin(phase)) * amplitude
                        phase += 2 * .pi * frequency / rate
                        if phase > 2 * .pi { phase -= 2 * .pi }
                        if samplePos % UInt64(rate) < 48 { v = v + 0.6 } // 1 ms click each second
                        buf[2 * i] = v; buf[2 * i + 1] = v
                    }
                    buf.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 960) }
                    produced += 480
                    dataAvailable?.signal()
                }
                usleep(5_000)
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
#endif
