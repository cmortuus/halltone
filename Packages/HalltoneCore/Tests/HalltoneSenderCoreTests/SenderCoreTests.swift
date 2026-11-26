import Testing
import Foundation
import HalltoneCore
@testable import HalltoneSenderCore

/// The portable sender over loopback with a synthetic tone: pairing, ACK/NAK, AUDIO, RESEND,
/// STATUS, keepalive timeout. Runs on macOS and on Ubuntu (CI).
@Suite(.serialized) struct SenderCoreTests {
    /// Starts a sender on a free port (nothing exposes the bound port, so probe a random one).
    static func startSender(gameMode: Bool = true, code: UInt32? = 1234, codec: CodecID = .pcm16,
                            configure: (SenderCore) -> Void = { _ in }) throws -> (SenderCore, UInt16) {
        var lastError: Error?
        for _ in 0..<20 {
            var cfg = SenderCore.Config()
            cfg.port = UInt16.random(in: 30_000...60_000)
            cfg.gameMode = gameMode
            cfg.codec = codec
            cfg.pairingCode = code
            cfg.advertise = false
            cfg.macName = "Test PC"
            let sender = SenderCore(config: cfg) { ToneSource(blockFrames: gameMode ? 128 : 480) }
            configure(sender)
            do { try sender.start(); return (sender, cfg.port) } catch { lastError = error }
        }
        throw lastError!
    }

    @Test func wrongPairingCodeIsRefused() throws {
        let (sender, port) = try Self.startSender()
        defer { sender.stop() }
        let c = TestClient(port: port)
        c.send(.subscribe(pairingCode: 9999, deviceName: "Phone", deviceID: "dev-1"))
        let reason = c.receive { p -> UInt8? in if case .subscribeNak(let r) = p.message { return r } else { return nil } }
        #expect(reason == NakReason.badPairingCode.rawValue)
    }

    @Test func subscribeAcksAndStreamsGameModeAudio() throws {
        let (sender, port) = try Self.startSender()
        defer { sender.stop() }
        let c = TestClient(port: port)
        c.send(.subscribe(pairingCode: 1234, deviceName: "Phone", deviceID: "dev-1"))

        var ackFrame: UInt16?
        var positions: [UInt64] = []
        var peak: Float = 0
        let decoder = PCM16Decoder(frameSamples: Constants.pcmGameFrameSamples)
        var pcm = [Float](repeating: 0, count: Constants.pcmGameFrameSamples * 2)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, positions.count < 100 {
            guard let p = c.receive(timeout: 0.5) else { continue }
            switch p.message {
            case .subscribeAck(let codec, let rate, let ch, let frame, let name):
                #expect(codec == .pcm16)
                #expect(rate == 48_000)
                #expect(ch == 2)
                #expect(name == "Test PC")
                ackFrame = frame
            case .audio(let pos, let codec, let payload):
                #expect(codec == .pcm16)
                positions.append(pos)
                payload.withUnsafeBytes { raw in
                    if decoder.decode(raw, into: &pcm) { peak = max(peak, pcm.map { abs($0) }.max() ?? 0) }
                }
            default: break
            }
        }
        #expect(ackFrame == UInt16(Constants.pcmGameFrameSamples))
        #expect(positions.count >= 100, "got \(positions.count) audio packets")
        #expect(peak > 0.05, "decoded tone is silent (peak \(peak))")
        // Consecutive frames; a single localhost listener should not lose any.
        for (a, b) in zip(positions, positions.dropFirst()) {
            #expect(b == a + UInt64(Constants.pcmGameFrameSamples), "gap between \(a) and \(b)")
        }
        #expect(sender.stats.subscribers.count == 1)
    }

    @Test func resendReturnsTheOriginalDatagram() throws {
        let (sender, port) = try Self.startSender()
        defer { sender.stop() }
        let c = TestClient(port: port)
        c.send(.subscribe(pairingCode: 1234, deviceName: "Phone", deviceID: "dev-1"))
        var first: [UInt64: Data] = [:]
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, first.count < 20 {
            if let p = c.receive(timeout: 0.5), case .audio(let pos, _, let payload) = p.message { first[pos] = payload }
        }
        let wanted = first.keys.sorted()[5]
        c.send(.resend(samplePositions: [wanted]))
        // The resent datagram arrives again with the same payload (the live stream carries
        // other positions, so only a duplicate of `wanted` can match).
        var dupes = 0
        let end = Date().addingTimeInterval(2)
        while Date() < end, dupes == 0 {
            if let p = c.receive(timeout: 0.3), case .audio(let pos, _, let payload) = p.message, pos == wanted {
                #expect(payload == first[wanted])
                dupes += 1
            }
        }
        #expect(dupes == 1)
    }

    @Test func keepaliveFromUnknownPeerIsToldToSubscribeAgain() throws {
        let (sender, port) = try Self.startSender()
        defer { sender.stop() }
        let c = TestClient(port: port)
        c.send(.keepalive(lastSeqReceived: 0, lossPermille: 0, bufferMs: 50))
        let reason = c.receive { p -> UInt8? in if case .subscribeNak(let r) = p.message { return r } else { return nil } }
        #expect(reason == NakReason.notSubscribed.rawValue)
    }

    @Test func statusIsSentOnlyWhenControlsAreReported() throws {
        // No controlsAvailable hook (the Linux sender): no STATUS packets.
        let (plain, plainPort) = try Self.startSender()
        defer { plain.stop() }
        let c1 = TestClient(port: plainPort)
        c1.send(.subscribe(pairingCode: 1234, deviceName: "Phone", deviceID: "d"))
        let none: StatusFlags? = c1.receive(timeout: 1) { p in if case .status(let f) = p.message { return f } else { return nil } }
        #expect(none == nil)

        // With the hook reporting false (Linux: no media keys), STATUS arrives with the flag clear.
        let (withStatus, port) = try Self.startSender { $0.controlsAvailable = { false } }
        defer { withStatus.stop() }
        let c2 = TestClient(port: port)
        c2.send(.subscribe(pairingCode: 1234, deviceName: "Phone", deviceID: "d"))
        let flags: StatusFlags? = c2.receive { p in if case .status(let f) = p.message { return f } else { return nil } }
        #expect(flags != nil)
        #expect(flags?.contains(.controlsAvailable) == false)
    }

    @Test func byeRemovesTheSubscriberAndStopsCapture() throws {
        let (sender, port) = try Self.startSender()
        defer { sender.stop() }
        let c = TestClient(port: port)
        c.send(.subscribe(pairingCode: 1234, deviceName: "Phone", deviceID: "d"))
        _ = c.receive { p -> Bool? in if case .audio = p.message { return true } else { return nil } }
        #expect(sender.stats.subscribers.count == 1 || sender.hasListeningSubscriber)
        c.send(.bye)
        let end = Date().addingTimeInterval(2)
        while Date() < end, sender.hasListeningSubscriber { Thread.sleep(forTimeInterval: 0.05) }
        #expect(!sender.hasListeningSubscriber)
    }

    @Test func opusCodecIsAdvertisedWhenNotInGameMode() throws {
        let (sender, port) = try Self.startSender(gameMode: false, codec: .opus)
        defer { sender.stop() }
        let c = TestClient(port: port)
        c.send(.subscribe(pairingCode: 1234, deviceName: "Phone", deviceID: "d"))
        let ack: (CodecID, UInt16)? = c.receive { p in
            if case .subscribeAck(let codec, _, _, let frame, _) = p.message { return (codec, frame) } else { return nil }
        }
        #expect(ack?.0 == .opus)
        #expect(ack?.1 == UInt16(Constants.opusFrameSamples))
    }
}
