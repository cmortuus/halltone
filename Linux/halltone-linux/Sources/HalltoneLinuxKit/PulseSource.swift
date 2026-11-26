#if canImport(CPulseSimple)
import Foundation
import CPulseSimple
import HalltoneCore
import HalltoneSenderCore
#if canImport(os)
import os
#endif

private let log = Logger(subsystem: Constants.logSubsystem, category: "Pulse")

/// Captures what the PC is playing: the PulseAudio simple API recording from the default sink's
/// monitor (`@DEFAULT_MONITOR@`) at 48 kHz float32 stereo with a small fragment size. On Ubuntu's
/// default PipeWire this goes through pipewire-pulse.
///
/// Recovery: a supervisor thread (re)starts a reader whenever there isn't a healthy one. A server
/// restart makes reads fail, so the reader exits and a new one opens after a second; a changed
/// default sink (polled through `pactl`) starts a reader on the new sink and abandons the old
/// one. The ring just keeps filling; the sender paces out silence while nothing arrives.
public final class PulseSource: AudioSource {
    public var dataAvailable: DispatchSemaphore?
    public var sampleRate: Double? { lock.locked { started ? Constants.sampleRate : nil } }

    private let device: String
    private let fragmentFrames: Int
    private let lock = NSLock()
    private var started = false
    private var ring: RingBuffer?
    private var reader: Reader?
    private var supervisor: Thread?

    /// One connection to the server. Abandoned readers free their stream the next time a read
    /// returns (a suspended sink delivers nothing, so that can take until something plays).
    private final class Reader {
        let lock = NSLock()
        /// Ring writes go through the gate, so an abandoned reader can't write after `abandon()`.
        let gate = ProducerGate()
        private var _failed = false
        var failedAt = Date.distantPast
        let sink: String?
        init(sink: String?) { self.sink = sink }
        var abandoned: Bool { gate.abandoned }
        func abandon() { gate.abandon() }
        var failed: Bool { lock.locked { _failed } }
        func fail() { lock.locked { _failed = true; failedAt = Date() } }
    }

    /// - Parameters:
    ///   - device: PulseAudio source name (default: monitor of the default sink).
    ///   - fragmentFrames: record fragment size in frames: 120 = 2.5 ms.
    public init(device: String = "@DEFAULT_MONITOR@", fragmentFrames: Int = 120) {
        self.device = device
        self.fragmentFrames = max(48, fragmentFrames)
    }

    public func start(into ring: RingBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        self.ring = ring
        let t = Thread { [self] in supervise() }
        t.name = "com.halltone.pulse.supervisor"
        supervisor = t
        t.start()
    }

    public func stop() {
        lock.lock()
        started = false
        let r = reader
        reader = nil
        supervisor = nil
        ring = nil
        lock.unlock()
        r?.abandon()
    }

    private var isStarted: Bool { lock.locked { started } }

    private func supervise() {
        var lastPoll = Date.distantPast
        var openedAt = Date.distantPast
        while isStarted {
            let current = lock.locked { reader }
            if let current, !current.abandoned {
                if current.failed {
                    // Server gone or sink removed: reopen after a second.
                    if Date().timeIntervalSince(current.failedAt) >= 1 { replace(old: current) }
                } else if Date().timeIntervalSince(lastPoll) >= 2, Date().timeIntervalSince(openedAt) >= 2 {
                    lastPoll = Date()
                    if let sink = DefaultSink.current(), let opened = current.sink, sink != opened {
                        log.notice("default output changed (\(opened, privacy: .public) → \(sink, privacy: .public)); switching capture")
                        replace(old: current)
                    }
                }
            } else {
                replace(old: nil)
            }
            if lock.locked({ reader }) !== current { openedAt = Date() }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func replace(old: Reader?) {
        old?.abandon()
        let sink = DefaultSink.current()
        let r = Reader(sink: sink)
        let frames = fragmentFrames
        let dev = device
        guard let ring = lock.locked({ () -> RingBuffer? in
            guard started else { return nil }
            reader = r
            return self.ring
        }) else { return }
        let t = Thread { [self] in capture(r, ring: ring, device: dev, frames: frames) }
        t.name = "com.halltone.pulse.read"
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func capture(_ r: Reader, ring: RingBuffer, device: String, frames: Int) {
        var spec = pa_sample_spec(format: PA_SAMPLE_FLOAT32LE, rate: 48_000, channels: 2)
        let bytes = frames * 2 * MemoryLayout<Float>.size
        var attr = pa_buffer_attr(maxlength: UInt32.max, tlength: UInt32.max, prebuf: UInt32.max,
                                  minreq: UInt32.max, fragsize: UInt32(bytes))
        var err: Int32 = 0
        guard let s = pa_simple_new(nil, "Halltone", PA_STREAM_RECORD, device, "System audio",
                                    &spec, nil, &attr, &err) else {
            log.error("can't open \(device, privacy: .public): \(String(cString: pa_strerror(err)), privacy: .public); retrying")
            r.fail()
            return
        }
        defer { pa_simple_free(s) }
        log.notice("capturing \(device, privacy: .public) (sink \(r.sink ?? "unknown", privacy: .public)), \(frames) frame fragments")
        var buf = [Float](repeating: 0, count: frames * 2)
        while !r.abandoned {
            let rc = buf.withUnsafeMutableBytes { pa_simple_read(s, $0.baseAddress, bytes, &err) }
            if r.abandoned { return }
            if rc < 0 {
                log.error("read failed: \(String(cString: pa_strerror(err)), privacy: .public)")
                r.fail()
                return
            }
            let wrote = buf.withUnsafeBufferPointer { r.gate.write(ring, $0.baseAddress!, count: frames * 2) }
            if !wrote { return }
            dataAvailable?.signal()
        }
    }
}

private extension NSLock {
    func locked<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
#endif
