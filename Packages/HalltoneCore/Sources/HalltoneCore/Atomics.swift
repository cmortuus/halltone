import CHalltone

/// Heap-allocated atomic counters for use between a real-time callback and worker threads.
public final class AtomicCounter {
    private let p: UnsafeMutablePointer<UInt32>
    public init() { p = .allocate(capacity: 1); p.initialize(to: 0) }
    deinit { p.deallocate() }
    @inline(__always) public func add(_ d: UInt32 = 1) { es_atomic_add_u32(p, d) }
    @inline(__always) public func load() -> UInt32 { es_atomic_load_u32(p) }
    @inline(__always) public func exchange(_ v: UInt32) -> UInt32 { es_atomic_exchange_u32(p, v) }
}

public final class AtomicUInt64 {
    private let p: UnsafeMutablePointer<UInt64>
    public init(_ v: UInt64 = 0) { p = .allocate(capacity: 1); p.initialize(to: v) }
    deinit { p.deallocate() }
    @inline(__always) public func add(_ d: UInt64) { es_atomic_add_u64(p, d) }
    @inline(__always) public func load() -> UInt64 { es_atomic_load_u64(p) }
    @inline(__always) public func store(_ v: UInt64) { es_atomic_store_u64(p, v) }
}
