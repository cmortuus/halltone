import Testing
import Foundation
@testable import HalltoneCore

@Suite struct PacketTests {
    @Test func roundTrips() {
        let messages: [Message] = [
            .subscribe(pairingCode: 1234, deviceName: "Caleb’s iPhone"),
            .subscribe(pairingCode: 1234, deviceName: "Caleb’s iPhone", deviceID: "5E0D7A1C-0000-4000-8000-000000000001"),
            .keepalive(lastSeqReceived: 99, lossPermille: 12, bufferMs: 60),
            .bye,
            .resend(samplePositions: [0, 480, 960, UInt64.max]),
            .subscribeAck(codec: .pcm16, sampleRate: 48000, channels: 2, frameSamples: 240, macName: "Mac Studio"),
            .subscribeNak(reason: 1),
            .status(flags: [.controlsAvailable]),
            .status(flags: [.lastControlFailed]),
            .nudge,
            .audio(samplePos: 1 << 40, codec: .pcm16, payload: Data((0..<960).map { UInt8($0 & 0xff) })),
            .control(command: .next),
            .remoteControl(pairingCode: 4821, command: .pauseForPeer, requestID: 0xCAFE_F00D, peerName: "Gaming PC"),
            .remoteControl(pairingCode: 4821, command: .resumeForPeer, requestID: 1, peerName: ""),
            .remoteControlAck(requestID: 0xCAFE_F00D, result: .paused),
            .remoteControlAck(requestID: 7, result: .disabled),
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

    @Test func remoteControlWireLayout() {
        // Payload after the 12-byte header: code u32, command u8, request id u32, name (u8 len + UTF-8).
        let req = Packet(seq: 1, session: 2, message: .remoteControl(pairingCode: 0x0102_0304, command: .resumeForPeer,
                                                                    requestID: 0x0A0B_0C0D, peerName: "PC")).encode()
        #expect(req[3] == 0x21)
        #expect(Array(req.dropFirst(Header.size)) == [1, 2, 3, 4, 2, 0x0A, 0x0B, 0x0C, 0x0D, 2, 0x50, 0x43])
        let ack = Packet(seq: 1, session: 2, message: .remoteControlAck(requestID: 0x0A0B_0C0D, result: .resumeSkipped)).encode()
        #expect(ack[3] == 0x22)
        #expect(Array(ack.dropFirst(Header.size)) == [0x0A, 0x0B, 0x0C, 0x0D, 4])
    }

    @Test func remoteControlRejectsMalformed() {
        let good = Packet(seq: 1, session: 2, message: .remoteControl(pairingCode: 1, command: .pauseForPeer, requestID: 3, peerName: "pc")).encode()
        for n in 0..<good.count { #expect(Packet.decode(good.prefix(n)) == nil) } // every truncation
        var bad = good; bad[Header.size + 4] = 9 // unknown command
        #expect(Packet.decode(bad) == nil)
        let ack = Packet(seq: 1, session: 2, message: .remoteControlAck(requestID: 3, result: .paused)).encode()
        #expect(Packet.decode(ack.prefix(ack.count - 1)) == nil)
        bad = ack; bad[ack.count - 1] = 0 // unknown result
        #expect(Packet.decode(bad) == nil)
    }

    @Test func longNamesTruncate() {
        let name = String(repeating: "é", count: 300)
        let p = Packet(seq: 0, session: 0, message: .subscribe(pairingCode: 0, deviceName: name))
        guard case .subscribe(_, let decoded, _)? = Packet.decode(p.encode())?.message else { Issue.record("decode failed"); return }
        #expect(decoded.utf8.count <= 255)
        #expect(decoded.hasPrefix("ééé"))
    }
}
