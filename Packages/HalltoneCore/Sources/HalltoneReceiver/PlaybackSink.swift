import Foundation
import HalltoneCore

/// Where decoded PCM goes. The real sink is an AVAudioEngine source node; tests and the CLI can
/// substitute a file writer that paces itself like a render callback.
public protocol PlaybackSink: AnyObject {
    /// Interleaved stereo 48 kHz float hand-off ring. The decode pump writes, the render side reads.
    var ring: RingBuffer { get }
    /// Incremented by the render side each time it had to output silence.
    var underruns: AtomicCounter { get }
    /// Total frames rendered (including silence), for latency bookkeeping.
    var renderedFrames: AtomicUInt64 { get }
    /// Signaled by the render side after each callback so the decode pump can sleep instead of poll.
    var wake: DispatchSemaphore { get }
    /// Largest number of frames the render side has asked for in one callback (0 if unknown).
    /// Over Bluetooth iOS can request 1024–4096 frames at once, so the pump must keep at least
    /// this much decoded ahead or every callback underruns.
    var maxCallbackFrames: AtomicCounter { get }
    func start() throws
    func stop()
    /// The output AudioUnit (as a raw pointer) whose real-time workgroup the decode pump joins,
    /// and a counter that changes whenever it's replaced. nil/0 for sinks without one.
    var outputAudioUnit: UnsafeMutableRawPointer? { get }
    var outputGeneration: UInt32 { get }
}

extension PlaybackSink {
    public var outputAudioUnit: UnsafeMutableRawPointer? { nil }
    public var outputGeneration: UInt32 { 0 }
}
