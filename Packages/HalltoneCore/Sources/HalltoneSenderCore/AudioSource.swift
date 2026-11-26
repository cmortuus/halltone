import Foundation
import HalltoneCore

/// A source of system audio. Implementations push interleaved stereo Float32 samples into the
/// ring buffer from a real-time callback (or a reader thread) and must never allocate, lock, or
/// log in a real-time callback.
public protocol AudioSource: AnyObject {
    /// Native capture sample rate in Hz; valid after `start`. Anything other than 48 kHz is
    /// resampled by the `AudioResampler` from `makeResampler()`.
    var sampleRate: Double? { get }
    /// Signaled from the capture callback after each write, so the consumer can sleep instead of poll.
    var dataAvailable: DispatchSemaphore? { get set }
    func start(into ring: RingBuffer) throws
    func stop()
    /// A converter from `sampleRate` to 48 kHz stereo. nil: no conversion available (the source
    /// delivers 48 kHz, as every Linux source does).
    func makeResampler() -> AudioResampler?
}

public extension AudioSource {
    func makeResampler() -> AudioResampler? { nil }
}

/// Converts captured audio to the wire rate. Platform glue: the Mac uses AVAudioConverter.
public protocol AudioResampler: AnyObject {
    /// Drains whatever is available from `input` (interleaved stereo Float32 at the source rate)
    /// and appends the converted 48 kHz stereo frames to `output`.
    func process(from input: RingBuffer, into output: RingBuffer)
}
