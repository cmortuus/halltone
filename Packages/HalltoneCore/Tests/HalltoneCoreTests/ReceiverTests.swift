import Testing
@testable import HalltoneReceiver

struct ReceiverTests {
    /// Regression: after a reconnect the jitter buffer's totals restart at zero; the old wrapping
    /// subtraction overflowed when summed and crashed the app (Receiver.everySecond).
    @Test func counterDeltasSurviveAReset() {
        let fresh = Receiver.counterDeltas(lost: 2, received: 100, lastLost: 50, lastReceived: 90_000)
        #expect(fresh.lost == 2 && fresh.received == 100)
        let normal = Receiver.counterDeltas(lost: 55, received: 90_100, lastLost: 50, lastReceived: 90_000)
        #expect(normal.lost == 5 && normal.received == 100)
    }
}
