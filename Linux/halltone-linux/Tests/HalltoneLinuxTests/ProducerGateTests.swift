import Testing
import Foundation
import HalltoneCore
@testable import HalltoneLinuxKit

@Suite struct ProducerGateTests {
    /// After `abandon()` returns, the old producer must never write again, however hard it is
    /// hammering the gate at that moment.
    @Test func noWriteAfterAbandonReturns() async throws {
        for _ in 0..<50 {
            let ring = RingBuffer(capacity: 1 << 12)
            let gate = ProducerGate()
            let stop = AtomicFlag()
            let t = Thread {
                var sample: Float = 1
                while !stop.isSet {
                    if !gate.write(ring, &sample, count: 1) { break }
                    ring.reset() // keep the ring from filling; irrelevant to the gate
                }
            }
            t.start()
            Thread.sleep(forTimeInterval: 0.002)
            gate.abandon()
            let after = gate.writes
            Thread.sleep(forTimeInterval: 0.005)
            #expect(gate.writes == after, "a write landed after abandon() returned")
            #expect(gate.abandoned)
            stop.set()
        }
    }

    @Test func abandonedGateRefusesWrites() {
        let ring = RingBuffer(capacity: 64)
        let gate = ProducerGate()
        var x: Float = 0.5
        #expect(gate.write(ring, &x, count: 1))
        gate.abandon()
        #expect(!gate.write(ring, &x, count: 1))
        #expect(ring.availableToRead == 1)
    }
}

private final class AtomicFlag {
    private let lock = NSLock()
    private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}
