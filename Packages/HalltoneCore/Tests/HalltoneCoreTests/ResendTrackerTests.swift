#if canImport(HalltoneReceiver)
import Testing
@testable import HalltoneReceiver

struct ResendTrackerTests {
    static let frame = 120          // 2.5 ms
    static let cap = 0.030
    func tracker() -> ResendTracker { ResendTracker(frameSamples: Self.frame) }
    func pos(_ n: Int) -> UInt64 { UInt64(n * Self.frame) }

    @Test func windowIsFiveMsOrTwoFrames() {
        #expect(abs(ResendTracker(frameSamples: 120).window - 0.005) < 1e-9)
        #expect(abs(ResendTracker(frameSamples: 960).window - 0.040) < 1e-9)   // 2 x 20 ms
    }

    @Test func reorderedPacketIsNeverRequested() {
        var t = tracker()
        _ = t.received(pos: pos(0), at: 0, cap: Self.cap)
        _ = t.received(pos: pos(2), at: 0.0025, cap: Self.cap)         // hole at 1
        let a = t.due(at: 0.0025, cap: Self.cap, limit: 64)
        let b = t.due(at: 0.004, cap: Self.cap, limit: 64)
        #expect(a.isEmpty && b.isEmpty)
        let filled = t.received(pos: pos(1), at: 0.0045, cap: Self.cap)   // arrives by itself
        #expect(filled)
        let c = t.due(at: 0.1, cap: Self.cap, limit: 64)
        #expect(c.isEmpty)
    }

    @Test func holeIsRequestedOnceTheWindowRunsOut() {
        var t = tracker()
        _ = t.received(pos: pos(0), at: 0, cap: Self.cap)
        _ = t.received(pos: pos(3), at: 0.0075, cap: Self.cap)         // holes at 1 and 2
        let early = t.due(at: 0.0075 + 0.0049, cap: Self.cap, limit: 64)
        #expect(early.isEmpty)
        let ask = t.due(at: 0.0075 + 0.005, cap: Self.cap, limit: 64)
        #expect(ask == [pos(1), pos(2)])
        let again = t.due(at: 0.1, cap: Self.cap, limit: 64)
        #expect(again.isEmpty)                                          // not asked twice here
        let tooSoon = t.retries(at: 0.0125 + 0.1, limit: 64)
        #expect(tooSoon.isEmpty)
        let retry = t.retries(at: 0.0125 + 0.16, limit: 64)
        #expect(retry == [pos(1), pos(2)])
        let third = t.retries(at: 0.0125 + 0.4, limit: 64)
        #expect(third.isEmpty)                                          // only one retry
        let gone = t.retries(at: 3, limit: 64)
        #expect(gone.isEmpty && t.holes.isEmpty)                        // forgotten
    }

    @Test func windowWidensWhenPacketsArriveJustBeforeItEnds() {
        var t = tracker()
        _ = t.received(pos: pos(0), at: 0, cap: Self.cap)
        _ = t.received(pos: pos(2), at: 0.001, cap: Self.cap)
        let filled = t.received(pos: pos(1), at: 0.001 + 0.0045, cap: Self.cap)   // 4.5 ms into a 5 ms window
        #expect(filled)
        #expect(t.window >= 0.0075 - 1e-9)
        // Early arrivals don't widen it.
        let w = t.window
        _ = t.received(pos: pos(4), at: 0.02, cap: Self.cap)
        _ = t.received(pos: pos(3), at: 0.0201, cap: Self.cap)
        #expect(t.window == w)
    }

    @Test func windowIsCappedAndRelaxes() {
        var t = tracker()
        var now = 0.0
        var n = 0
        _ = t.received(pos: pos(n), at: now, cap: 0.012)
        for _ in 0..<10 {   // always arrives just before the window ends
            let w = t.effectiveWindow(cap: 0.012)
            _ = t.received(pos: pos(n + 2), at: now, cap: 0.012)
            now += w * 0.95
            _ = t.received(pos: pos(n + 1), at: now, cap: 0.012)
            n += 2
        }
        #expect(t.effectiveWindow(cap: 0.012) <= 0.012)
        #expect(t.window > 0.012)                                   // grew past this cap, held back by it
        #expect(t.effectiveWindow(cap: 0.0) == t.frameDuration)   // a tiny buffer shrinks it to one frame
        for i in 1...60 { t.relax(at: now + 3 + Double(i) * 0.25) }
        #expect(abs(t.window - t.baseWindow) < 1e-6)
    }

    @Test func realLossStillGetsRequestedWithinTheCap() {
        var t = tracker()
        _ = t.received(pos: pos(0), at: 0, cap: 0.012)
        _ = t.received(pos: pos(2), at: 0.0025, cap: 0.012)          // pos(1) is lost for good
        var asked: [UInt64] = []
        var now = 0.0025
        while asked.isEmpty && now < 1 { now += 0.0025; asked = t.due(at: now, cap: 0.012, limit: 64) }
        #expect(asked == [pos(1)])
        #expect(now - 0.0025 <= 0.012 + 0.0025)
    }

    @Test func hugeGapsAreOutagesNotLoss() {
        var t = tracker()
        _ = t.received(pos: pos(0), at: 0, cap: Self.cap)
        _ = t.received(pos: pos(5000), at: 0.01, cap: Self.cap)
        #expect(t.holes.isEmpty)
    }
}
#endif
