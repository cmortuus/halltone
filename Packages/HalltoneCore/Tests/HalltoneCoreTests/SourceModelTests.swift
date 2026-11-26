import Testing
import Foundation
@testable import HalltoneCore

struct SourceSettingsTests {
    @Test func startsEmptyAndRemembersWhatIsTurnedOn() {
        let store = MemorySettingsStore()
        let s = SourceSettings(store: store)
        #expect(s.isEmpty && s.enabled.isEmpty)
        s.enable("bonjour:Studio Mac")
        s.enable("manual:10.0.0.9:47800")
        s.enable("bonjour:Studio Mac") // again: no duplicate
        #expect(s.enabled == ["bonjour:Studio Mac", "manual:10.0.0.9:47800"])
        #expect(!SourceSettings(store: store).isEmpty)
    }

    @Test func persistsAcrossLaunches() {
        let store = MemorySettingsStore()
        let first = SourceSettings(store: store)
        first.enable("a"); first.enable("b")
        first.update("b") { $0.volume = 0.4; $0.muted = true; $0.latency = .lowest }
        first.disable("a")

        let second = SourceSettings(store: store)
        #expect(second.enabled == ["b"])
        #expect(second.config(for: "b") == SourceConfig(volume: 0.4, muted: true, latency: .lowest))
        #expect(second.config(for: "a") == SourceConfig(), "unknown and never-touched sources are at defaults")
    }

    @Test func defaultsLeaveNoEntryAndVolumeIsClamped() {
        let s = SourceSettings(store: MemorySettingsStore())
        s.update("a") { $0.volume = 3 }
        #expect(s.config(for: "a").volume == 1 && s.configs["a"] == nil)
        s.update("a") { $0.volume = -1 }
        #expect(s.config(for: "a").volume == 0)
        s.update("a") { $0.volume = 1 }
        #expect(s.configs.isEmpty)
    }

    @Test func forgetDropsEverything() {
        let store = MemorySettingsStore()
        let s = SourceSettings(store: store)
        s.enable("a"); s.update("a") { $0.muted = true }
        s.forget("a")
        let reloaded = SourceSettings(store: store)
        #expect(reloaded.enabled.isEmpty && reloaded.configs.isEmpty)
    }

    @Test func aCorruptStoreIsIgnored() {
        let store = MemorySettingsStore()
        store.set(Data("not json".utf8), forKey: SourceSettings.key)
        #expect(SourceSettings(store: store).enabled.isEmpty)
    }
}

struct LatencyDefaultTests {
    @Test func autoForMacsGameForTwoAndAHalfMillisecondFrames() {
        #expect(LatencyMode.resolve(choice: nil, frameSamples: 240) == .auto)
        #expect(LatencyMode.resolve(choice: nil, frameSamples: 480) == .auto)
        #expect(LatencyMode.resolve(choice: nil, frameSamples: 0) == .auto)
        #expect(LatencyMode.resolve(choice: nil, frameSamples: 120) == .game)
    }

    @Test func anExplicitPickWins() {
        #expect(LatencyMode.resolve(choice: .auto, frameSamples: 120) == .auto)
        #expect(LatencyMode.resolve(choice: .stable, frameSamples: 120) == .stable)
        #expect(LatencyMode.resolve(choice: .game, frameSamples: 480) == .game)
    }
}

struct MediaSourceChooserTests {
    private func c(_ id: String, controls: Bool? = true, playing: Bool = true, at t: TimeInterval = 0) -> MediaSourceCandidate {
        MediaSourceCandidate(id: id, controlsAvailable: controls, playing: playing, playingChangedAt: t)
    }

    @Test func noSourcesNoChoice() {
        #expect(MediaSourceChooser.choose([]) == nil)
    }

    @Test func sourcesWithoutControlsAreNeverChosen() {
        #expect(MediaSourceChooser.choose([c("game", controls: false, at: 9), c("old", controls: nil, at: 9)]) == nil)
        #expect(MediaSourceChooser.choose([c("game", controls: false, at: 9), c("mac", at: 1)]) == "mac")
    }

    @Test func theMostRecentlyPlayingOneWins() {
        #expect(MediaSourceChooser.choose([c("a", at: 1), c("b", at: 5), c("c", at: 3)]) == "b")
    }

    @Test func aPlayingSourceBeatsOneThatStopped() {
        // b stopped later than a started, but a is playing now.
        #expect(MediaSourceChooser.choose([c("a", playing: true, at: 1), c("b", playing: false, at: 8)]) == "a")
    }

    @Test func whenNothingPlaysTheLastToStopWins() {
        #expect(MediaSourceChooser.choose([c("a", playing: false, at: 4), c("b", playing: false, at: 7)]) == "b")
    }

    @Test func tiesKeepTheCurrentChoiceThenTheListOrder() {
        let tied = [c("a", at: 2), c("b", at: 2)]
        #expect(MediaSourceChooser.choose(tied) == "a")
        #expect(MediaSourceChooser.choose(tied, current: "b") == "b")
        #expect(MediaSourceChooser.choose(tied, current: "gone") == "a")
    }
}
