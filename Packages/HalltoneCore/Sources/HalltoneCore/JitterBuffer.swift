import Foundation

/// Packet jitter buffer keyed by stream sample position.
///
/// Pure logic, no threads: the owner serializes `push`/`pull` with a lock. `pull` is designed to
/// be driven by a decode thread that keeps a small PCM hand-off ring ahead of the render callback;
/// `playoutAhead` is how many samples are already decoded but not yet rendered, so that
/// depth = playoutAhead + buffered span is the true playout delay.
public final class JitterBuffer {
    public struct Config {
        public var frameSamples: Int
        public var sampleRate: Double = Constants.sampleRate
        public var initialTargetMs: Double = 60
        public var minTargetMs: Double = 30
        /// Phones in Wi-Fi power save can receive in bursts with 200–300 ms holes; the ceiling
        /// has to cover those or every hole becomes an audible dropout.
        public var maxTargetMs: Double = 400
        /// The target never drops below (largest recent gap between packet arrivals + this).
        public var gapMarginMs: Double = 30
        /// How quickly the remembered largest gap fades (half-life).
        public var gapHalfLifeSeconds: Double = 30
        /// Fast catch-up: if depth is this far above target (instantaneous) and half that on
        /// average, drop a frame as often as every `catchUpInterval`.
        public var catchUpMarginMs: Double = 80
        public var catchUpInterval: TimeInterval = 0.05
        /// A network gap longer than this resets and re-primes; shorter gaps just pause playout.
        public var stallResetSeconds: Double = 1.0
        /// Low-latency behavior: during a network gap keep playing concealment (Opus PLC) instead
        /// of pausing, for up to `maxConcealMs`; packets for the concealed time are then dropped.
        /// Latency stays put at the cost of a brief blip.
        public var concealGaps = false
        public var maxConcealMs: Double = 300
        /// Raise target by this much on an underrun.
        public var raiseStepMs: Double = 20
        /// Packets that arrive after their play time (3 in a second) raise the target. Off in
        /// Game mode, where the packets that follow a concealed gap arrive "late" by design.
        public var raiseOnLate = true
        /// The decode pump keeps at least this much decoded ahead of the render callback (0 = just
        /// one callback plus one frame), and may grow that slack by up to `maxExtraDecodedAheadMs`
        /// when the render side runs dry while packets are queued (the pump was late).
        public var minDecodedAheadMs: Double = 20
        public var maxExtraDecodedAheadMs: Double = 100
        /// Give back one frame of that slack after this many seconds without a render underrun
        /// (0 = keep it for the session). Game mode only: its slack costs latency directly.
        public var extraDecodedAheadDecaySeconds: Double = 0
        /// Lower target by this much after `lowerAfterSeconds` without an underrun.
        public var lowerStepMs: Double = 5
        public var lowerAfterSeconds: TimeInterval = 10
        /// Drift correction kicks in when smoothed depth is this far from target.
        public var driftToleranceMs: Double = 15
        public var minAdjustInterval: TimeInterval = 1.0
        /// How long after the screen locks the fast lock-floor growth may run (iOS pulls ahead
        /// ~2.5 s in); after that, drift correction alone holds the floor.
        public var lockGrowSeconds: TimeInterval = 5
        /// A jump in samplePos larger than this (either direction) flushes and re-primes.
        public var resetJumpSeconds: Double = 1.0

        public init(frameSamples: Int) { self.frameSamples = frameSamples }
    }

    public enum Pull: Equatable {
        /// Nothing to emit right now (not primed, or waiting for data).
        case wait
        /// Decode and emit this frame.
        case frame(pos: UInt64, payload: Data)
        /// Frame at `pos` is missing. `next` is the following packet, if present, for FEC.
        case conceal(pos: UInt64, next: Data?)
        /// Drift correction: `dropped` was removed; decode both and emit one crossfaded frame.
        case dropped(pos: UInt64, dropped: Data, nextPos: UInt64, next: Data)
        /// Drift correction: emit one bridging frame before `next` (which stays queued).
        case duplicate(nextPos: UInt64, next: Data)

        /// Stream position of the frame this pull emits (nil for `.wait`).
        public var samplePos: UInt64? {
            switch self {
            case .wait: return nil
            case .frame(let p, _), .conceal(let p, _), .dropped(let p, _, _, _): return p
            case .duplicate(let p, _): return p
            }
        }
    }

    public struct Stats: Equatable {
        public var targetMs: Double = 0
        public var depthMs: Double = 0
        public var received: UInt64 = 0
        public var lost: UInt64 = 0
        public var late: UInt64 = 0
        public var duplicates: UInt64 = 0
        public var underruns: UInt64 = 0
        public var driftDrops: UInt64 = 0
        public var driftDups: UInt64 = 0
        public var resets: UInt64 = 0
        public var primed = false
        public init() {}
    }

    public private(set) var config: Config
    private var concealedRun = 0
    public private(set) var stats = Stats()
    public var frameSamples: Int { config.frameSamples }

    private var session: UInt32?
    private var expectedPos: UInt64 = 0
    private var hasExpected = false
    private var primed = false
    /// Sorted ascending by pos.
    private var queue: [(pos: UInt64, payload: Data)] = []
    private var targetSamples: Int
    private var depthEMA: Double = 0
    private var lastUnderrunTime: TimeInterval = 0
    private var lastRaiseTime: TimeInterval = -1
    private var lastLowerTime: TimeInterval = 0
    private var lastAdjustTime: TimeInterval = 0
    private var lastEmitTime: TimeInterval = 0
    private var startedTime: TimeInterval = 0
    private var lateWindowStart: TimeInterval = 0
    private var lateInWindow = 0
    private var lastArrival: TimeInterval?
    private var gapPeakMs: Double = 0
    private var lastGapUpdate: TimeInterval = 0
    private var lastFastDrop: TimeInterval = 0
    private var lockGrowUntil: TimeInterval = 0

    /// Largest recent gap between packet arrivals (decaying), in ms.
    public var recentGapMs: Double { gapPeakMs }

    public init(config: Config) {
        self.config = config
        targetSamples = Int(config.initialTargetMs * config.sampleRate / 1000)
        stats.targetMs = config.initialTargetMs
    }

    // MARK: - Input

    public func push(session: UInt32, samplePos: UInt64, payload: Data, now: TimeInterval) {
        if let s = self.session, s != session {
            reset(now: now)
        }
        if self.session == nil { self.session = session; startedTime = now; lastLowerTime = now }
        stats.received += 1
        noteArrival(now: now)

        // A deep buffer legitimately holds packets up to maxTarget (plus catch-up slack) ahead of
        // the play head; only a jump well beyond that is a new stream. With a fixed 1 s limit, a
        // target above 1 s reset on every packet and could never prime again: permanent silence.
        let jumpSeconds = max(config.resetJumpSeconds,
                              (config.maxTargetMs + config.catchUpMarginMs) / 1000 + 1)
        let jump = UInt64(jumpSeconds * config.sampleRate)
        if hasExpected {
            if samplePos + jump < expectedPos || samplePos > expectedPos + jump {
                reset(now: now)
                self.session = session
            } else if samplePos < expectedPos {
                stats.late += 1
                noteLate(now: now)
                return
            }
        }
        if !hasExpected {
            expectedPos = samplePos
            hasExpected = true
        }
        // Insert sorted; drop duplicates.
        var lo = 0, hi = queue.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if queue[mid].pos < samplePos { lo = mid + 1 } else { hi = mid }
        }
        if lo < queue.count, queue[lo].pos == samplePos {
            stats.duplicates += 1
            return
        }
        queue.insert((samplePos, payload), at: lo)
        // While unprimed, the oldest queued packet is where playback will start.
        if !primed, let first = queue.first, first.pos < expectedPos {
            expectedPos = first.pos
        }
    }

    // MARK: - Output

    /// `concealBelow`: with `concealGaps`, an empty queue is concealed only while the decoded
    /// hand-off holds less than this many samples (about one render callback). Above it there is
    /// still audio to play, so wait for the packet: concealing early (the pump keeps more than
    /// a callback decoded ahead) would run ahead of the stream and turn every arrival late.
    public func pull(playoutAhead: Int, now: TimeInterval, concealBelow: Int = .max) -> Pull {
        guard hasExpected else { return .wait }
        let frame = UInt64(config.frameSamples)
        let span = bufferedSpan()

        if !primed {
            // Prime once we hold a target's worth of audio (or the hand-off already has it).
            if span + playoutAhead >= targetSamples, !queue.isEmpty {
                primed = true
                stats.primed = true
                depthEMA = Double(targetSamples)
                lastEmitTime = now
                lastAdjustTime = now
            } else {
                return .wait
            }
        }

        if queue.isEmpty, config.concealGaps, playoutAhead < concealBelow,
           Double(concealedRun) < config.maxConcealMs * config.sampleRate / 1000 {
            let pos = expectedPos
            expectedPos += frame
            concealedRun += config.frameSamples
            stats.lost += 1
            lastEmitTime = now
            return .conceal(pos: pos, next: nil)
        }
        if queue.isEmpty {
            // Network gap. Short gaps just pause playout (content is kept and the catch-up below
            // trims the extra delay afterwards); only a long outage resets and re-primes.
            let stallLimit = max(config.stallResetSeconds, 2 * Double(targetSamples) / config.sampleRate)
            if now - lastEmitTime > stallLimit {
                primed = false
                stats.primed = false
                hasExpected = false
            }
            return .wait
        }

        // Depth tracking (EMA, ~0.5 s time constant at 100 pulls/s).
        let depth = Double(span + playoutAhead)
        depthEMA += 0.02 * (depth - depthEMA)
        stats.depthMs = depthEMA * 1000 / config.sampleRate
        maybeLowerTarget(now: now)

        lastEmitTime = now
        let tol = config.driftToleranceMs * config.sampleRate / 1000
        // Fast catch-up after an outage piled up data: well above target both right now and on
        // average (so the normal refill after a Wi-Fi burst doesn't trigger it).
        let catchUp = config.catchUpMarginMs * config.sampleRate / 1000
        if depth > Double(targetSamples) + catchUp, depthEMA > Double(targetSamples) + catchUp / 2,
           now - lastFastDrop >= config.catchUpInterval, queue.count >= 2,
           queue[0].pos == expectedPos, queue[1].pos == expectedPos + frame {
            let a = queue.removeFirst()
            let b = queue.removeFirst()
            expectedPos += 2 * frame
            stats.driftDrops += 1
            lastFastDrop = now
            return .dropped(pos: a.pos, dropped: a.payload, nextPos: b.pos, next: b.payload)
        }
        // Growing to a lock floor: about 2.5 s after the screen locks iOS pulls ~130 ms ahead
        // (it deepens its output buffer), so get there first, a crossfaded 10 ms repeat every
        // 150 ms, judged on the instantaneous depth (the smoothed one lags). Only right after
        // the lock: on clumped Wi-Fi the instantaneous depth dips below the floor between clumps
        // all the time, and repeating at every dip while drift drops at every peak warbles.
        if lockFloorMs > 0, now < lockGrowUntil, depth < Double(targetSamples) - tol,
           now - lastAdjustTime >= 0.15, queue[0].pos == expectedPos {
            stats.driftDups += 1
            lastAdjustTime = now
            depthEMA += Double(frame)
            return .duplicate(nextPos: queue[0].pos, next: queue[0].payload)
        }
        if now - lastAdjustTime >= config.minAdjustInterval {
            if depthEMA > Double(targetSamples) + tol, queue.count >= 2,
               queue[0].pos == expectedPos, queue[1].pos == expectedPos + frame {
                let a = queue.removeFirst()
                let b = queue.removeFirst()
                expectedPos += 2 * frame
                stats.driftDrops += 1
                lastAdjustTime = now
                depthEMA = Double(targetSamples)
                return .dropped(pos: a.pos, dropped: a.payload, nextPos: b.pos, next: b.payload)
            }
            if depthEMA < Double(targetSamples) - tol, queue[0].pos == expectedPos {
                stats.driftDups += 1
                lastAdjustTime = now
                depthEMA = Double(targetSamples)
                return .duplicate(nextPos: queue[0].pos, next: queue[0].payload)
            }
        }

        let head = queue[0]
        if head.pos == expectedPos {
            queue.removeFirst()
            expectedPos += frame
            concealedRun = 0
            return .frame(pos: head.pos, payload: head.payload)
        }
        // head.pos > expectedPos: the expected frame is lost (or still in flight, but later data
        // has already arrived, so we don't wait for it).
        let pos = expectedPos
        expectedPos += frame
        stats.lost += 1
        let next = head.pos == expectedPos ? head.payload : nil
        return .conceal(pos: pos, next: next)
    }

    /// Audio still queued here but not yet decoded, in samples.
    public var queuedSamples: Int { bufferedSpan() }

    /// The render side ran dry. Raises the target (rate-limited) only when this buffer was itself
    /// empty, i.e. the network fell behind. If packets were queued, the decode thread was simply
    /// late (screen lock, CPU throttling) and a deeper network buffer would not have helped;
    /// raising anyway ratcheted the target past a second over a few minutes.
    public func reportUnderrun(now: TimeInterval) {
        stats.underruns += 1
        guard queuedSamples < 2 * config.frameSamples else { return }
        lastUnderrunTime = now
        if now - lastRaiseTime >= 0.5 {
            setTarget(ms: stats.targetMs + config.raiseStepMs)
            lastRaiseTime = now
        }
    }

    public func flush(now: TimeInterval) { reset(now: now) }

    /// Switch latency behavior. Flushes and re-primes at the new starting depth.
    public func updateConfig(_ new: Config, now: TimeInterval) {
        var c = new
        c.frameSamples = config.frameSamples
        config = c
        gapPeakMs = 0
        setTarget(ms: c.initialTargetMs)
        reset(now: now)
    }

    /// Switch latency behavior without flushing (Auto mode following the user to and from the
    /// Mac): the target jumps to the new mode's level and the depth follows it, trimmed by
    /// crossfaded drops or stretched by crossfaded duplicates, so there's no gap.
    public func retune(_ new: Config, now: TimeInterval) {
        var c = new
        c.frameSamples = config.frameSamples
        config = c
        setTarget(ms: max(c.initialTargetMs, min(c.maxTargetMs, gapPeakMs + c.gapMarginMs)))
        lastUnderrunTime = now // hold off lowering for a while
    }

    /// Packets arriving after their play time are a jitter signal too: several in one second
    /// means the target is too shallow, even if concealment hid the gaps.
    private func noteLate(now: TimeInterval) {
        if now - lateWindowStart > 1 { lateWindowStart = now; lateInWindow = 0 }
        lateInWindow += 1
        if config.raiseOnLate, lateInWindow >= 3, now - lastRaiseTime >= 0.5 {
            setTarget(ms: stats.targetMs + config.raiseStepMs)
            lastRaiseTime = now
            lastUnderrunTime = now
            lateInWindow = 0
        }
    }

    // MARK: - Internals

    private func bufferedSpan() -> Int {
        guard let last = queue.last else { return 0 }
        let end = last.pos + UInt64(config.frameSamples)
        return end > expectedPos ? Int(end - expectedPos) : 0
    }

    private func maybeLowerTarget(now: TimeInterval) {
        guard now - lastUnderrunTime >= config.lowerAfterSeconds,
              now - lastLowerTime >= config.lowerAfterSeconds,
              now - startedTime >= config.lowerAfterSeconds else { return }
        decayGapPeak(now: now)
        let floor = gapPeakMs + config.gapMarginMs
        let lowered = max(stats.targetMs - config.lowerStepMs, floor)
        if lowered < stats.targetMs { setTarget(ms: lowered) }
        lastLowerTime = now
    }

    /// Packets that arrive in bursts (Wi-Fi power save) leave holes; size the target to cover
    /// the largest recent hole directly instead of creeping up after each underrun.
    private func noteArrival(now: TimeInterval) {
        defer { lastArrival = now }
        guard let last = lastArrival else { lastGapUpdate = now; return }
        decayGapPeak(now: now)
        let gapMs = (now - last) * 1000
        // Gaps of a second or more are outages (handled by stall/re-prime), not jitter. So are
        // gaps longer than the ceiling: no allowed target could cover them, and counting them
        // pinned the target at the ceiling for minutes. (A locked iPhone's Wi-Fi goes silent for
        // ~0.5 s every minute or two, e.g. scanning for access points.)
        guard gapMs < config.stallResetSeconds * 1000, gapMs <= config.maxTargetMs else { return }
        if gapMs > gapPeakMs { gapPeakMs = gapMs }
        let wanted = min(config.maxTargetMs, gapPeakMs + config.gapMarginMs)
        if wanted > stats.targetMs {
            setTarget(ms: wanted)
            lastUnderrunTime = now // hold off lowering for a while
        }
    }

    private func decayGapPeak(now: TimeInterval) {
        let dt = now - lastGapUpdate
        guard dt > 0 else { return }
        gapPeakMs *= pow(0.5, dt / config.gapHalfLifeSeconds)
        lastGapUpdate = now
    }

    /// Minimum depth while the phone's screen is locked (0 = none). See the lock-floor growth in
    /// `pull`: iOS pulls ~100-130 ms ahead a couple of seconds after the screen locks.
    public private(set) var lockFloorMs: Double = 0

    public func setLockFloor(ms: Double, now: TimeInterval) {
        guard ms != lockFloorMs else { return }
        lockFloorMs = ms
        lockGrowUntil = ms > 0 ? now + config.lockGrowSeconds : 0
        if ms > 0 {
            setTarget(ms: stats.targetMs)
        } else {
            // Back to what the network needs; catch-up and drift trim the extra (iOS also hands
            // its pulled-ahead audio back on unlock).
            setTarget(ms: max(config.initialTargetMs, min(config.maxTargetMs, gapPeakMs + config.gapMarginMs)))
        }
        lastUnderrunTime = now
    }

    private func setTarget(ms: Double) {
        let clamped = min(max(config.maxTargetMs, lockFloorMs), max(config.minTargetMs, lockFloorMs, ms))
        stats.targetMs = clamped
        targetSamples = Int(clamped * config.sampleRate / 1000)
    }

    private func reset(now: TimeInterval) {
        lastArrival = nil
        concealedRun = 0
        queue.removeAll(keepingCapacity: true)
        primed = false
        stats.primed = false
        hasExpected = false
        session = nil
        stats.resets += 1
        startedTime = now
        lastLowerTime = now
    }
}


/// User-facing latency/robustness trade-off.
public enum LatencyMode: String, CaseIterable, Codable {
    /// Stable while nobody is using the Mac, lowest while someone is (the Mac reports it).
    /// Listening away from the Mac wants no dropouts; sitting back down wants lip sync. Default.
    case auto
    /// Smallest buffer that still covers the gaps the network actually has: tighter margin and
    /// faster shrink than balanced. (Concealing gaps instead of waiting sounded awful on Wi-Fi
    /// with power-save bursts: every gap past a fixed cap became a blip plus a skip.)
    case lowest
    /// Adapts to the network: covers the gaps it actually sees.
    case balanced
    /// Big buffer that rides out Wi-Fi access-point handoffs, dead spots and a locked phone's
    /// Wi-Fi blackouts without dropouts.
    case stable
    /// Phone on the desk next to the computer, app in the foreground and screen on, wired or
    /// USB-C headphones: about 15 ms of jitter buffer, 2.5 ms frames (Mac "Game mode"). Rare short
    /// fades instead of a bigger buffer when Wi-Fi hiccups; Bluetooth headphones add their own
    /// 150-250 ms on top.
    case game
}

extension JitterBuffer.Config {
    /// `.auto` has no preset of its own: the receiver picks lowest or stable. Asked directly, it
    /// gets stable (the away-from-the-Mac case it exists for).
    public static func preset(_ mode: LatencyMode, frameSamples: Int) -> JitterBuffer.Config {
        var c = JitterBuffer.Config(frameSamples: frameSamples)
        switch mode {
        case .auto:
            return preset(.stable, frameSamples: frameSamples)
        case .lowest:
            c.initialTargetMs = 40
            c.minTargetMs = 20
            c.maxTargetMs = 250
            c.gapMarginMs = 15
            c.gapHalfLifeSeconds = 20
            c.raiseStepMs = 10
            c.catchUpMarginMs = 40
        case .balanced:
            break
        case .game:
            // Numbers from the loopback/JitterSim measurements in the PR. Gaps up to the 60 ms
            // ceiling still grow the target (to gap + margin); anything longer (Wi-Fi power
            // save, ~100 ms) is ignored and concealed with a short fade out and in instead.
            c.initialTargetMs = 15
            c.minTargetMs = 8
            c.maxTargetMs = 60
            c.gapMarginMs = 5
            c.gapHalfLifeSeconds = 6
            c.raiseStepMs = 5
            c.lowerStepMs = 5
            c.lowerAfterSeconds = 2
            c.driftToleranceMs = 5
            c.minAdjustInterval = 0.25
            c.catchUpMarginMs = 20
            c.catchUpInterval = 0.02
            c.concealGaps = true
            c.maxConcealMs = 120
            c.raiseOnLate = false
            c.minDecodedAheadMs = 0
            c.maxExtraDecodedAheadMs = 40
            c.extraDecodedAheadDecaySeconds = 3
        case .stable:
            c.initialTargetMs = 300
            c.minTargetMs = 250
            c.maxTargetMs = 1500
            c.gapMarginMs = 120
            c.gapHalfLifeSeconds = 120
            c.lowerAfterSeconds = 30
            c.catchUpMarginMs = 300
            c.stallResetSeconds = 4
        }
        return c
    }
}

extension JitterBuffer.Config {
    /// Used automatically when the phone is on cellular (e.g. reaching home over a VPN): cellular
    /// links have 50-150 ms of round-trip jitter and occasional multi-hundred-ms stalls.
    public static func cellular(frameSamples: Int) -> JitterBuffer.Config {
        var c = JitterBuffer.Config(frameSamples: frameSamples)
        c.initialTargetMs = 400
        c.minTargetMs = 300
        c.maxTargetMs = 2000
        c.gapMarginMs = 150
        c.gapHalfLifeSeconds = 120
        c.lowerAfterSeconds = 30
        c.catchUpMarginMs = 400
        c.stallResetSeconds = 6
        return c
    }
}

