import Foundation
import HalltoneCore

/// Fixed ring of recent audio datagrams (preallocated, no allocation on the encode thread), so a
/// phone's RESEND can be answered with the original packet.
final class DatagramHistory {
    private let slots: Int
    private let capacity = Packet.audioOverhead + 1500
    private let storage: UnsafeMutablePointer<UInt8>
    private var lengths: [Int]
    private var positions: [UInt64]
    private var next = 0
    private let lock = NSLock()

    init(slots: Int) {
        self.slots = slots
        storage = .allocate(capacity: slots * capacity)
        lengths = [Int](repeating: 0, count: slots)
        positions = [UInt64](repeating: .max, count: slots)
    }

    deinit { storage.deallocate() }

    func store(_ ptr: UnsafePointer<UInt8>, _ len: Int, samplePos: UInt64) {
        guard len <= capacity else { return }
        lock.lock()
        (storage + next * capacity).update(from: ptr, count: len)
        lengths[next] = len
        positions[next] = samplePos
        next = (next + 1) % slots
        lock.unlock()
    }

    /// Calls `body` with the stored datagram for `samplePos`; false if it's no longer kept.
    @discardableResult
    func withDatagram(samplePos: UInt64, _ body: (UnsafeRawPointer, Int) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let i = positions.firstIndex(of: samplePos) else { return false }
        body(UnsafeRawPointer(storage + i * capacity), lengths[i])
        return true
    }
}
