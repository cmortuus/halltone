import Testing
import Foundation
import HalltoneCore
import HalltoneSenderCore
@testable import HalltoneLinuxKit

/// A bus that never answers, and doesn't time out either (a backend that wedges inside the call).
private final class HangingBackend: MPRISBackend {
    let never = DispatchSemaphore(value: 0)
    func players() throws -> [MPRISPlayer] { never.wait(); return [] }
    func send(_ command: MPRISCommand, to bus: String) -> Bool { never.wait(); return false }
}

/// Field failure (#25 follow-up): a sender with a phone subscribed stopped sending AUDIO for 90 s.
/// Nothing media-related may sit on the sender's queue, its receive thread or the encode path.
@Suite(.serialized, .timeLimit(.minutes(2))) struct StallTests {
    private func audioCount(_ h: MediaSenderHarness, seconds: Double) -> Int {
        var n = 0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if let p = h.client.receive(timeout: 0.1), case .audio = p.message { n += 1 } }
        return n
    }

    @Test func audioKeepsFlowingWhileTheMediaControllerBlocksForever() throws {
        let media = MediaController(backend: HangingBackend())
        media.startPolling(interval: 0.1); defer { media.stopPolling() }
        let h = try MediaSenderHarness(media: media)
        #expect(audioCount(h, seconds: 1) > 20)          // streaming before
        h.control(.playPause)                            // a media key into the wedged bus
        h.control(.next)
        _ = h.remote(.pauseForPeer)                             // and a REMOTE_CONTROL request
        let during = audioCount(h, seconds: 3)           // sender ticks (STATUS asks the controller) keep running
        #expect(during > 100, "only \(during) audio packets in 3 s with a wedged media controller")
        // The sender's own queue still answers (its tick isn't stuck behind the bus).
        #expect(h.status(timeout: 6) != nil)
    }

    @Test func theWatchdogStaysQuietWhileAudioFlows() throws {
        let port = UInt16.random(in: 30_000...60_000)
        var config = SenderCore.Config()
        config.port = port; config.pairingCode = 4321; config.advertise = false; config.macName = "Test PC"
        let sender = SenderCore(config: config) { ToneSource(blockFrames: 480) }
        sender.watchdogStallSeconds = 0.5
        try sender.start(); defer { sender.stop() }
        let client = TestClient(port: port)
        for _ in 0..<25 {
            client.send(.subscribe(pairingCode: 4321, deviceName: "Phone", deviceID: "wd"))
            if (client.receive(timeout: 0.4) { p -> Bool? in if case .subscribeAck = p.message { return true }; return nil }) == true { break }
        }
        var n = 0
        let end = Date().addingTimeInterval(3)
        while Date() < end { if let p = client.receive(timeout: 0.1), case .audio = p.message { n += 1 } }
        #expect(n > 50)
        #expect(sender.watchdogRestarts.load() == 0)
        #expect(!SenderCore.threadStates().isEmpty)
    }
}
