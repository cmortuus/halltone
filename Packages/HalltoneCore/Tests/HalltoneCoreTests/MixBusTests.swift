import Testing
@testable import HalltoneCore

struct SoftLimiterTests {
    @Test func belowTheKneePassesUntouched() {
        for v: Float in [0, 0.1, -0.5, 0.9, -0.9] { #expect(SoftLimiter.apply(v) == v) }
    }

    @Test func bendsTowardOneWithoutReachingIt() {
        var last: Float = 0.9
        for v: Float in [0.95, 1, 1.5, 2, 4, 100] {
            let y = SoftLimiter.apply(v)
            #expect(y > last && y < 1, "\(v) → \(y)")
            #expect(SoftLimiter.apply(-v) == -y)
            last = y
        }
    }

    @Test func processMatchesApplyAndIsInPlace() {
        var x: [Float] = [0.2, -0.95, 1.7, -3, 0.9]
        let expected = x.map(SoftLimiter.apply)
        x.withUnsafeMutableBufferPointer { SoftLimiter.process($0.baseAddress!, count: $0.count) }
        #expect(x == expected)
    }
}

struct MixBusTests {
    /// Renders `frames` frames, after queueing the same constant (l, r) per channel.
    private func render(_ bus: MixBus, _ inputs: [(PlaybackChannel, Float, Float)], frames: Int = 128) -> (l: [Float], r: [Float], starved: Int) {
        for (ch, l, r) in inputs {
            var block = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames { block[2 * i] = l; block[2 * i + 1] = r }
            block.withUnsafeBufferPointer { _ = ch.ring.write($0.baseAddress!, count: block.count) }
        }
        var l = [Float](repeating: 9, count: frames), r = [Float](repeating: 9, count: frames)
        let starved = l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in bus.render(left: lp.baseAddress!, right: rp.baseAddress!, frames: frames) }
        }
        return (l, r, starved)
    }

    @Test func sumsTheChannels() throws {
        let bus = MixBus()
        let a = try #require(bus.claimChannel()), b = try #require(bus.claimChannel())
        try a.attach(); try b.attach()
        let out = render(bus, [(a, 0.2, -0.1), (b, 0.3, 0.05)])
        #expect(out.starved == 0)
        for i in 0..<128 {
            #expect(abs(out.l[i] - 0.5) < 1e-6)
            #expect(abs(out.r[i] - -0.05) < 1e-6)
        }
    }

    /// One source at full volume under the knee must come out bit for bit as it went in.
    @Test func oneSourceIsUntouched() throws {
        let bus = MixBus()
        let a = try #require(bus.claimChannel())
        try a.attach()
        let out = render(bus, [(a, 0.7, -0.85)])
        #expect(out.l.allSatisfy { $0 == 0.7 } && out.r.allSatisfy { $0 == -0.85 })
    }

    @Test func limitsTheSumNotTheStreams() throws {
        let bus = MixBus()
        let a = try #require(bus.claimChannel()), b = try #require(bus.claimChannel())
        try a.attach(); try b.attach()
        // Each stream is under the knee (0.8); together they are 1.6.
        let out = render(bus, [(a, 0.8, -0.8), (b, 0.8, -0.8)])
        #expect(out.l.allSatisfy { $0 == SoftLimiter.apply(1.6) })
        #expect(out.r.allSatisfy { $0 == -SoftLimiter.apply(1.6) })
        #expect(out.l[0] > 0.9 && out.l[0] < 1)
    }

    @Test func volumeIsSquaredAndGlidesIn() throws {
        let bus = MixBus()
        let a = try #require(bus.claimChannel())
        try a.attach()
        a.volume = 0.5
        #expect(a.targetGain == 0.25)
        let ramp = render(bus, [(a, 0.4, 0.4)])
        #expect(ramp.l[0] > ramp.l[127], "glides down over the first callback")
        #expect(abs(ramp.l[127] - 0.1) < 1e-5)
        let steady = render(bus, [(a, 0.4, 0.4)])
        #expect(steady.l.allSatisfy { abs($0 - 0.1) < 1e-6 })
    }

    @Test func muteSilencesAChannelButKeepsDrainingIt() throws {
        let bus = MixBus()
        let a = try #require(bus.claimChannel()), b = try #require(bus.claimChannel())
        try a.attach(); try b.attach()
        a.muted = true
        _ = render(bus, [(a, 0.5, 0.5), (b, 0.1, 0.1)]) // glide
        let out = render(bus, [(a, 0.5, 0.5), (b, 0.1, 0.1)])
        #expect(out.l.allSatisfy { abs($0 - 0.1) < 1e-6 }, "only b is heard")
        #expect(a.ring.availableToRead == 0, "a's ring is still consumed, so it stays live")
        a.muted = false
        _ = render(bus, [(a, 0.5, 0.5), (b, 0.1, 0.1)])
        let back = render(bus, [(a, 0.5, 0.5), (b, 0.1, 0.1)])
        #expect(back.l.allSatisfy { abs($0 - 0.6) < 1e-6 })
    }

    @Test func masterMuteIsSilenceAndLeavesTheRings() throws {
        let bus = MixBus()
        let a = try #require(bus.claimChannel())
        try a.attach()
        bus.muted = true
        let out = render(bus, [(a, 0.5, 0.5)])
        #expect(out.l.allSatisfy { $0 == 0 } && out.r.allSatisfy { $0 == 0 })
        #expect(a.ring.availableToRead == 256)
        #expect(a.renderedFrames.load() == 128)
    }

    @Test func aDryChannelCountsAnUnderrunAndOthersKeepPlaying() throws {
        let bus = MixBus()
        let a = try #require(bus.claimChannel()), b = try #require(bus.claimChannel())
        try a.attach(); try b.attach()
        let out = render(bus, [(b, 0.25, 0.25)])
        #expect(out.starved == 1)
        #expect(a.underruns.load() == 1 && b.underruns.load() == 0)
        #expect(out.l.allSatisfy { abs($0 - 0.25) < 1e-6 })
    }

    @Test func detachedChannelsAreNotRead() throws {
        let bus = MixBus()
        let a = try #require(bus.claimChannel())
        let out = render(bus, [(a, 0.5, 0.5)])
        #expect(out.l.allSatisfy { $0 == 0 })
        #expect(a.ring.availableToRead == 256)
        #expect(a.maxCallbackFrames.load() == 0)
    }

    @Test func tracksTheLargestCallback() throws {
        let bus = MixBus()
        let a = try #require(bus.claimChannel())
        try a.attach()
        _ = render(bus, [], frames: 240)
        _ = render(bus, [], frames: 120)
        #expect(a.maxCallbackFrames.load() == 240)
    }

    @Test func outputStartsWithTheFirstSourceAndStopsWithTheLast() throws {
        let bus = MixBus()
        var starts = 0, stops = 0
        bus.startHook = { starts += 1 }
        bus.stopHook = { stops += 1 }
        let a = try #require(bus.claimChannel()), b = try #require(bus.claimChannel())
        try a.attach()
        try b.attach()
        #expect(bus.attachedCount == 2)
        a.detach()
        #expect(stops == 0, "adding or removing a source doesn't stop the output while another plays")
        a.detach() // again: no effect
        b.detach()
        #expect(stops == 1 && bus.attachedCount == 0)
        #expect(starts == 2, "the hook is idempotent and may run on each attach")
    }

    @Test func aFailedStartLeavesTheChannelOut() throws {
        struct Boom: Error {}
        let bus = MixBus()
        bus.startHook = { throw Boom() }
        let a = try #require(bus.claimChannel())
        #expect(throws: Boom.self) { try a.attach() }
        #expect(!a.isAttached)
    }

    @Test func claimAndRelease() throws {
        let bus = MixBus()
        let all = (0..<MixBus.maxChannels).compactMap { _ in bus.claimChannel() }
        #expect(all.count == MixBus.maxChannels)
        #expect(bus.claimChannel() == nil)
        try all[3].attach()
        bus.release(all[3])
        #expect(!all[3].isAttached)
        let again = try #require(bus.claimChannel())
        #expect(again === all[3])
        #expect(again.volume == 1 && !again.muted)
    }

    @Test func aReclaimedChannelStartsClean() throws {
        let bus = MixBus()
        let old = try #require(bus.claimChannel())
        try old.attach()
        _ = render(bus, [(old, 0.5, 0.5)]) // plays, leaves nothing...
        _ = render(bus, [])                // ...then runs dry once (an underrun)
        var leftover = [Float](repeating: 0.5, count: 512)
        leftover.withUnsafeMutableBufferPointer { _ = old.ring.write($0.baseAddress!, count: 512) }
        old.wake.signal()
        bus.release(old)
        #expect(old.ring.availableToRead == 512, "the old source's audio is still queued at release")

        let next = try #require(bus.claimChannel())
        #expect(next === old)
        #expect(next.ring.availableToRead == 0)
        #expect(next.underruns.load() == 0 && next.renderedFrames.load() == 0 && next.maxCallbackFrames.load() == 0)
        #expect(next.wake.wait(timeout: .now()) == .timedOut, "no stale wake-ups")
        try next.attach()
        let first = render(bus, [])
        #expect(first.l.allSatisfy { $0 == 0 } && first.r.allSatisfy { $0 == 0 }, "nothing of the old source is heard")
        // New data plays, and only that (after the 64-frame fade-in that follows a dry callback).
        let fresh = render(bus, [(next, 0.25, 0.25)])
        #expect(fresh.l[64...].allSatisfy { abs($0 - 0.25) < 1e-6 })
    }
}
