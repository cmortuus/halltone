#if os(macOS)
import Foundation
import AVFoundation
import HalltoneCore

/// A source of system audio. Implementations push interleaved Float32 samples into
/// the ring buffer from a real-time callback and must never allocate, lock, or log there.
public protocol AudioSource: AnyObject {
    /// Native capture format; valid after `start`.
    var format: AVAudioFormat? { get }
    /// Signaled from the capture callback after each write, so the consumer can sleep instead of poll.
    var dataAvailable: DispatchSemaphore? { get set }
    func start(into ring: RingBuffer) throws
    func stop()
}
#endif
