import Testing
import Foundation
import HalltoneCore
import HalltoneSenderCore
@testable import HalltoneLinuxKit

func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}

/// A real `LinuxSender` (tone source) on a random port with a UDP client standing in for the phone:
/// the phone-side half of media controls, against whatever MPRIS backend the controller has.
final class MediaSenderHarness {
    let sender: LinuxSender
    let client: TestClient
    let code: UInt32 = 4321
    let peer = "Test Mac"
    private var nextID: UInt32 = 100

    init(media: MediaController, allowRemoteControl: Bool = true) throws {
        let port = UInt16.random(in: 30_000...60_000)
        var config = SenderCore.Config()
        config.port = port
        config.pairingCode = code
        config.advertise = false
        config.macName = "Test PC"
        sender = LinuxSender(config: config, media: media, allowRemoteControl: allowRemoteControl) { ToneSource(blockFrames: 480) }
        try sender.start()
        client = TestClient(port: port)
        subscribe()
    }

    deinit { sender.stop() }

    func subscribe() {
        for _ in 0..<25 {
            client.send(.subscribe(pairingCode: code, deviceName: "Phone", deviceID: "media-phone"))
            let acked: Bool? = client.receive(timeout: 0.4) { p in
                if case .subscribeAck = p.message { return true }
                return nil
            }
            if acked == true { return }
        }
    }

    /// The next STATUS flags (skipping audio), nil on timeout.
    func status(timeout: Double = 3) -> StatusFlags? {
        client.receive(timeout: timeout) { p in
            if case .status(let flags) = p.message { return flags }
            return nil
        }
    }

    /// STATUS packets until `match` accepts the flags.
    func waitForStatus(timeout: Double = 8, _ match: (StatusFlags) -> Bool) -> Bool {
        client.receive(timeout: timeout) { p -> Bool? in
            if case .status(let flags) = p.message, match(flags) { return true }
            return nil
        } ?? false
    }

    func control(_ c: ControlCommand) { client.send(.control(command: c)) }

    func remote(_ command: RemoteCommand, id: UInt32? = nil, code: UInt32? = nil) -> RemoteResult? {
        let rid = id ?? { nextID += 1; return nextID }()
        for _ in 0..<5 {   // the real peer retries the same id every 300 ms
            client.send(.remoteControl(pairingCode: code ?? self.code, command: command, requestID: rid, peerName: peer))
            let r: RemoteResult? = client.receive(timeout: 0.6) { p in
                if case .remoteControlAck(let ackID, let result) = p.message, ackID == rid { return result }
                return nil
            }
            if let r { return r }
        }
        return nil
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) struct MediaSenderTests {
    @Test func statusReportsControlsAndPlaybackFromMPRIS() throws {
        let fake = FakeMPRIS(); fake.add("firefox", .playing)
        let media = MediaController(backend: fake); media.startPolling(interval: 0.1); defer { media.stopPolling() }
        let h = try MediaSenderHarness(media: media)
        #expect(h.waitForStatus { $0.contains(.controlsAvailable) && $0.contains(.explicitPlayPause) && $0.contains(.macPlaying) })
        fake.set("firefox", .paused)
        #expect(h.waitForStatus { $0.contains(.controlsAvailable) && !$0.contains(.macPlaying) })
        fake.all = []
        #expect(h.waitForStatus { !$0.contains(.controlsAvailable) })
    }

    @Test func lockScreenCommandsDriveThePlayer() throws {
        let fake = FakeMPRIS(); fake.add("firefox", .playing)
        let media = MediaController(backend: fake)
        let h = try MediaSenderHarness(media: media)
        h.control(.pause)
        #expect(waitUntil { fake.status("firefox") == .paused })
        h.control(.play)
        #expect(waitUntil { fake.status("firefox") == .playing })
        h.control(.playPause)
        #expect(waitUntil { fake.status("firefox") == .paused })
        h.control(.playPause)
        #expect(waitUntil { fake.status("firefox") == .playing })
        h.control(.next); h.control(.previous)
        #expect(waitUntil { fake.commands.suffix(2) == ["Next org.mpris.MediaPlayer2.firefox", "Previous org.mpris.MediaPlayer2.firefox"] })
    }

    @Test func aFailedCommandIsReportedInStatus() throws {
        let fake = FakeMPRIS()   // no player
        let h = try MediaSenderHarness(media: MediaController(backend: fake))
        _ = h.status()
        h.control(.playPause)
        #expect(h.waitForStatus { $0.contains(.lastControlFailed) })
    }

    @Test func remoteControlPausesAndResumesThroughAPacket() throws {
        let fake = FakeMPRIS(); fake.add("firefox", .playing)
        let h = try MediaSenderHarness(media: MediaController(backend: fake))
        #expect(h.remote(.pauseForPeer) == .paused)
        #expect(fake.status("firefox") == .paused)
        #expect(h.remote(.resumeForPeer) == .resumed)
        #expect(fake.status("firefox") == .playing)
        // The user resumed by hand: nothing more to undo.
        #expect(h.remote(.pauseForPeer) == .paused)
        fake.set("firefox", .playing)
        #expect(h.remote(.resumeForPeer) == .resumeSkipped)
        // Nothing playing.
        fake.set("firefox", .paused)
        #expect(h.remote(.pauseForPeer) == .notPlaying)
        // Wrong code.
        #expect(h.remote(.pauseForPeer, code: 9999) == .badPairingCode)
    }

    @Test func allowRemoteControlOffAnswersDisabled() throws {
        let fake = FakeMPRIS(); fake.add("firefox", .playing)
        let h = try MediaSenderHarness(media: MediaController(backend: fake), allowRemoteControl: false)
        #expect(h.remote(.pauseForPeer) == .disabled)
        #expect(fake.status("firefox") == .playing)
        // Phone controls still work: they aren't REMOTE_CONTROL.
        h.control(.pause)
        #expect(waitUntil { fake.status("firefox") == .paused })
    }

    @Test func withoutAControllerBehaviorIsTheOldOne() throws {
        let port = UInt16.random(in: 30_000...60_000)
        var config = SenderCore.Config()
        config.port = port; config.pairingCode = 4321; config.advertise = false
        let sender = LinuxSender(config: config) { ToneSource(blockFrames: 480) }
        try sender.start(); defer { sender.stop() }
        let client = TestClient(port: port)
        for _ in 0..<25 { client.send(.subscribe(pairingCode: 4321, deviceName: "P", deviceID: "p")); if client.receive(timeout: 0.3) != nil { break } }
        let flags: StatusFlags? = client.receive(timeout: 3) { p in if case .status(let f) = p.message { return f }; return nil }
        #expect(flags?.contains(.controlsAvailable) == false)
    }
}
