import Foundation
import HalltoneCore

/// Makes "is this reader still the current producer?" and "write to the ring" one atomic step.
///
/// The capture ring is single-producer. When the default sink changes, the old reader is
/// abandoned and a new one starts writing the same ring; the old one may still be mid-read (a
/// `pa_simple_read` can't be interrupted). Checking a flag and then writing would leave a window
/// where both write. Here the write happens under the lock that `abandon()` takes, so once
/// `abandon()` returns the old reader can never touch the ring again.
final class ProducerGate {
    private let lock = NSLock()
    private var _abandoned = false
    private var _writes = 0

    var abandoned: Bool { lock.lock(); defer { lock.unlock() }; return _abandoned }
    /// Number of successful writes (for tests).
    var writes: Int { lock.lock(); defer { lock.unlock() }; return _writes }

    /// Marks this producer abandoned. Waits for a write in progress; none starts afterwards.
    func abandon() { lock.lock(); _abandoned = true; lock.unlock() }

    /// Writes `count` floats unless abandoned; false if abandoned. `tap` gets a copy under the same
    /// lock, so it too has a single producer.
    func write(_ ring: RingBuffer, _ samples: UnsafePointer<Float>, count: Int, tap: DialogTap? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !_abandoned else { return false }
        _ = ring.write(samples, count: count)
        tap?.push(samples, count: count)
        _writes += 1
        return true
    }
}
