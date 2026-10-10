import Testing
import Foundation
@testable import HalltoneCore

@Suite struct PacketTests {
    @Test func roundTrips() {
        let messages: [Message] = [
            .subscribe(pairingCode: 1234, deviceName: "Caleb’s iPhone"),
            .keepalive(lastSeqReceived: 99, lossPermille: 12, bufferMs: 60),
            .bye,
            .subscribeAck(codec: .pcm16, sampleRate: 48000, channels: 2, frameSamples: 240, macName: "Mac Studio"),
            .subscribeNak(reason: 1),
            .status(flags: [.controlsAvailable]),
            .status(flags: [.lastControlFailed]),
            .nudge,
            .audio(samplePos: 1 << 40, codec: .pcm16, payload: Data((0..<960).map { UInt8($0 & 0xff) })),
            .control(command: .next),
        ]
        for (i, m) in messages.enumerated() {
            let p = Packet(seq: UInt32(i), session: 0xDEADBEEF, message: m)
            let d = p.encode()
            #expect(d.count <= Constants.maxDatagramBytes)
            #expect(Packet.decode(d) == p)
            // Decoding must also work from a Data slice with a non-zero start index.
            let wrapped = Data([0xAA, 0xBB]) + d
            #expect(Packet.decode(wrapped[2...]) == p)
        }
    }

    @Test func rejectsMalformed() {
        let good = Packet(seq: 1, session: 2, message: .subscribe(pairingCode: 1, deviceName: "x")).encode()
        #expect(Packet.decode(Data()) == nil)
        #expect(Packet.decode(good.prefix(11)) == nil)
        var bad = good; bad[0] = 0x00
        #expect(Packet.decode(bad) == nil)
        bad = good; bad[2] = 9 // version
        #expect(Packet.decode(bad) == nil)
        bad = good; bad[3] = 0x77 // type
        #expect(Packet.decode(bad) == nil)
        // Audio with payloadLen larger than the datagram.
        var audio = Packet(seq: 1, session: 2, message: .audio(samplePos: 0, codec: .pcm16, payload: Data(repeating: 1, count: 10))).encode()
        audio[Header.size + 9] = 0xff
        #expect(Packet.decode(audio) == nil)
    }

    @Test func fuzzNeverCrashes() {
        var rng = SystemRandomNumberGenerator()
        let seeds = [
            Packet(seq: 5, session: 9, message: .audio(samplePos: 123, codec: .pcm16, payload: Data(repeating: 7, count: 100))).encode(),
            Packet(seq: 5, session: 9, message: .subscribeAck(codec: .opus, sampleRate: 48000, channels: 2, frameSamples: 480, macName: "m")).encode(),
        ]
        for _ in 0..<20_000 {
            var d = seeds[Int.random(in: 0..<seeds.count, using: &rng)]
            let flips = Int.random(in: 1...4, using: &rng)
            for _ in 0..<flips {
                let i = Int.random(in: 0..<d.count, using: &rng)
                d[i] = UInt8.random(in: 0...255, using: &rng)
            }
            if Bool.random(using: &rng) { d = d.prefix(Int.random(in: 0...d.count, using: &rng)) }
            _ = Packet.decode(d)
        }
        for _ in 0..<2_000 {
            let n = Int.random(in: 0...64, using: &rng)
            _ = Packet.decode(Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        }
    }

    @Test func longNamesTruncate() {
        let name = String(repeating: "é", count: 300)
        let p = Packet(seq: 0, session: 0, message: .subscribe(pairingCode: 0, deviceName: name))
        guard case .subscribe(_, let decoded)? = Packet.decode(p.encode())?.message else { Issue.record("decode failed"); return }
        #expect(decoded.utf8.count <= 255)
        #expect(decoded.hasPrefix("ééé"))
    }
}
