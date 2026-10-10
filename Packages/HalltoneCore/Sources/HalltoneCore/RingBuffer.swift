import CHalltone

/// Lock-free single-producer / single-consumer ring of interleaved Float samples.
/// `write` and `read` are real-time safe: no allocation, no locks.
public final class RingBuffer {
    private let ring: OpaquePointer

    public init(capacity: Int) {
        guard let r = es_ring_create(UInt32(capacity)) else {
            fatalError("RingBuffer: allocation failed")
        }
        ring = r
    }

    deinit { es_ring_destroy(ring) }

    public var capacity: Int { Int(es_ring_capacity(ring)) }
    public var availableToRead: Int { Int(es_ring_available_read(ring)) }
    public var availableToWrite: Int { Int(es_ring_available_write(ring)) }

    @inline(__always) @discardableResult
    public func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        Int(es_ring_write(ring, src, UInt32(count)))
    }

    @inline(__always) @discardableResult
    public func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        Int(es_ring_read(ring, dst, UInt32(count)))
    }

    @inline(__always) @discardableResult
    public func skip(_ count: Int) -> Int {
        Int(es_ring_skip(ring, UInt32(count)))
    }

    /// Only call while the producer is stopped.
    public func reset() { es_ring_reset(ring) }
}
