#if canImport(HalltoneReceiver)
import Testing
import Foundation
import Network
import HalltoneCore
@testable import HalltoneReceiver

/// Real receivers pointed at a port nobody listens on: they sit in "connecting", which is all the
/// manager's bookkeeping needs. Stats are injected through `handleStats`.
struct SourceManagerTests {
    private let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)
    private final class Clock { var t: TimeInterval = 100 }

    private func make(store: SettingsStore = MemorySettingsStore(), clock: Clock = Clock()) -> (SourceManager, MixBus, Clock) {
        let bus = MixBus()
        return (SourceManager(bus: bus, store: store, clock: { clock.t }), bus, clock)
    }

    private func wait(_ what: String, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !cond(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(cond(), "\(what)")
    }

    private func add(_ m: SourceManager, _ id: String) -> Source {
        m.connect(id: id, name: id, endpoint: endpoint, pairingCode: 1234, deviceName: "test")!
    }

    private func status(_ s: Source, in m: SourceManager, controls: Bool? = true, playing: Bool = true,
                        state: Receiver.State = .subscribed(macName: "x"), frameSamples: Int = 240) {
        var st = Receiver.Stats()
        st.state = state
        st.macControlsAvailable = controls
        st.macPlaying = playing
        st.frameSamples = frameSamples
        m.handleStats(s, st)
    }

    @Test func addsSourcesThatShareOneMix() {
        let (m, bus, _) = make()
        let a = add(m, "a"), b = add(m, "b")
        #expect(m.sources.map(\.id) == ["a", "b"])
        #expect(a.channel !== b.channel)
        wait("both join the mix") { bus.attachedCount == 2 }
        m.disconnectAll()
        wait("both leave") { bus.attachedCount == 0 }
    }

    @Test func connectingAgainReusesTheSource() {
        let (m, _, _) = make()
        let a = add(m, "a")
        #expect(add(m, "a") === a)
        #expect(m.sources.count == 1)
        m.disconnectAll()
    }

    @Test func removingFreesTheChannelAndForgetsTheSource() {
        let (m, bus, _) = make()
        let aChannel = add(m, "a").channel
        _ = add(m, "b")
        m.disconnect(id: "a")
        #expect(m.sources.map(\.id) == ["b"])
        #expect(m.settings.enabled == ["b"])
        wait("a leaves the mix") { bus.attachedCount == 1 }
        // Its channel comes back once the receiver is done with it.
        // Wait for the release without claiming anything (claiming would take the lowest free index).
        wait("a's channel is released") { !bus.isClaimed(aChannel) }
        let reclaimed = bus.claimChannel()
        #expect(reclaimed === aChannel)
        m.disconnectAll()
    }

    @Test func disconnectAllKeepsTheSetThatComesBackAtLaunch() {
        let store = MemorySettingsStore()
        let (m, _, _) = make(store: store)
        _ = add(m, "a"); _ = add(m, "b")
        m.disconnectAll()
        #expect(m.sources.isEmpty)
        #expect(SourceSettings(store: store).enabled == ["a", "b"])
    }

    @Test func persistsTheSetAndEachSourcesSettings() {
        let store = MemorySettingsStore()
        let (m, _, _) = make(store: store)
        _ = add(m, "a"); _ = add(m, "b")
        m.setVolume(0.3, for: "b")
        m.setMuted(true, for: "a")
        m.setLatency(.stable, for: "b")
        m.disconnect(id: "a")
        m.disconnectAll()

        // A new launch: same store.
        let (m2, bus2, _) = make(store: store)
        #expect(m2.settings.enabled == ["b"])
        let b = add(m2, "b")
        #expect(b.config == SourceConfig(volume: 0.3, muted: false, latency: .stable))
        #expect(b.channel.volume == 0.3)
        #expect(b.receiver.latencyMode == .stable && !b.receiver.gameFramesPlayAsGame)
        wait("joins") { bus2.attachedCount == 1 }
        m2.disconnectAll()
    }

    @Test func settingsApplyToTheLiveSource() {
        let (m, _, _) = make()
        let a = add(m, "a")
        #expect(a.receiver.latencyMode == .auto && a.receiver.gameFramesPlayAsGame, "default: Auto, Game for 2.5 ms frames")
        m.setVolume(0.5, for: "a")
        m.setMuted(true, for: "a")
        #expect(a.channel.volume == 0.5 && a.channel.muted && a.channel.targetGain == 0)
        m.setLatency(.lowest, for: "a")
        #expect(a.receiver.latencyMode == .lowest && !a.receiver.gameFramesPlayAsGame)
        m.setLatency(nil, for: "a")
        #expect(a.receiver.gameFramesPlayAsGame)
        m.disconnectAll()
    }

    @Test func globalSettingsReachEverySourceIncludingLaterOnes() {
        let (m, _, _) = make()
        let a = add(m, "a")
        m.listening = false
        m.holdHeadphones = true
        let b = add(m, "b")
        #expect(!a.receiver.listening && !b.receiver.listening)
        #expect(a.receiver.holdHeadphones && b.receiver.holdHeadphones)
        m.listening = true
        #expect(a.receiver.listening && b.receiver.listening)
        m.disconnectAll()
    }

    @Test func theMixHasRoomForEightSources() {
        let (m, _, _) = make()
        for i in 0..<MixBus.maxChannels { #expect(m.connect(id: "s\(i)", name: "s", endpoint: endpoint, pairingCode: 1, deviceName: "t") != nil) }
        #expect(m.isFull)
        #expect(m.connect(id: "extra", name: "x", endpoint: endpoint, pairingCode: 1, deviceName: "t") == nil)
        m.disconnectAll()
    }

    @Test func effectiveModeFollowsTheSendersFrames() {
        let (m, _, _) = make()
        let a = add(m, "a")
        status(a, in: m, frameSamples: 240)
        #expect(a.effectiveMode == .auto)
        status(a, in: m, frameSamples: 120)
        #expect(a.effectiveMode == .game)
        m.setLatency(.balanced, for: "a")
        #expect(a.effectiveMode == .balanced)
        m.disconnectAll()
    }

    // MARK: media source

    @Test func mediaSourceIsTheOneWithControlsThatStartedPlayingLast() {
        let (m, _, clock) = make()
        let mac = add(m, "mac"), pc = add(m, "pc"), game = add(m, "game")
        clock.t = 10; status(mac, in: m)
        clock.t = 20; status(pc, in: m)
        clock.t = 30; status(game, in: m, controls: false)
        #expect(m.mediaSource === pc, "game started last but has no controls")
        clock.t = 40; status(mac, in: m, playing: false); status(mac, in: m, playing: true)
        #expect(m.mediaSource === mac, "the Mac started playing again most recently")
        m.disconnectAll()
    }

    @Test func aPlayingSourceBeatsOneThatPaused() {
        let (m, _, clock) = make()
        let a = add(m, "a"), b = add(m, "b")
        clock.t = 1; status(a, in: m); status(b, in: m)
        clock.t = 5; status(b, in: m, playing: false)
        #expect(m.mediaSource === a)
        clock.t = 6; status(a, in: m); status(a, in: m) // repeated STATUS doesn't reorder anything
        #expect(m.mediaSource === a)
        m.disconnectAll()
    }

    @Test func repeatedStatusDoesNotFlipTheChoice() {
        let (m, _, clock) = make()
        let a = add(m, "a"), b = add(m, "b")
        clock.t = 1; status(a, in: m)
        clock.t = 2; status(b, in: m)
        for i in 3..<10 { clock.t = TimeInterval(i); status(a, in: m); status(b, in: m); #expect(m.mediaSource === b) }
        m.disconnectAll()
    }

    @Test func noSourceHasControlsMeansNoTargetUnlessItIsTheOnlyOne() {
        let (m, _, _) = make()
        let a = add(m, "a")
        status(a, in: m, controls: false)
        #expect(m.mediaSource === a, "alone: still targeted, so a Mac without controls can explain itself")
        let b = add(m, "b")
        status(b, in: m, controls: nil)
        #expect(m.mediaSource == nil)
        m.disconnectAll()
    }

    @Test func sourcesThatAreNotConnectedAreNotTargeted() {
        let (m, _, _) = make()
        let a = add(m, "a"), b = add(m, "b")
        status(a, in: m, state: .failed("x"))
        status(b, in: m, state: .reconnecting)
        #expect(m.mediaSource === b, "reconnecting still counts: its controls were reported")
        status(b, in: m, state: .rejected("wrong pairing code"))
        #expect(m.mediaSource == nil)
        m.disconnectAll()
    }

    @Test func removingTheMediaSourceHandsOverToTheNext() {
        let (m, _, clock) = make()
        let a = add(m, "a"), b = add(m, "b")
        clock.t = 1; status(a, in: m)
        clock.t = 2; status(b, in: m)
        #expect(m.mediaSource === b)
        m.disconnect(id: "b")
        #expect(m.mediaSource === a)
        m.disconnectAll()
    }
}
#endif
