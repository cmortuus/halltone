import Foundation

/// One source's path into the mix: its hand-off ring (the decode pump writes, the mixer reads),
/// render-side counters, and volume/mute. Obtained from `MixBus.claimChannel()`.
///
/// Everything the render thread touches is allocated up front and read through atomics, so adding
/// or removing a source never needs the audio engine to stop.
public final class PlaybackChannel {
    /// Interleaved stereo 48 kHz float hand-off ring.
    public let ring = RingBuffer(capacity: 1 << 17) // ~1.3 s stereo
    /// Incremented by the mixer each time this channel had to output silence.
    public let underruns = AtomicCounter()
    /// Total frames rendered (including silence), for latency bookkeeping.
    public let renderedFrames = AtomicUInt64()
    /// Signaled after each render callback so the decode pump can sleep instead of poll.
    public let wake = DispatchSemaphore(value: 0)
    /// Largest number of frames one render callback asked for.
    public let maxCallbackFrames = AtomicCounter()
    public let index: Int

    fileprivate weak var bus: MixBus?
    fileprivate let attachedFlag = AtomicUInt64()
    fileprivate let targetGainBits = AtomicUInt64(UInt64(Float(1).bitPattern))
    /// Render-thread-only state.
    fileprivate var renderGain: Float = 1
    fileprivate var starved = false

    fileprivate init(index: Int) { self.index = index }

    /// 0...1 as shown on the slider; the amplitude applied is its square, which feels even to the ear.
    public var volume: Float = 1 { didSet { updateGain() } }
    public var muted = false { didSet { updateGain() } }
    private func updateGain() {
        let v = min(1, max(0, volume))
        targetGainBits.store(UInt64((muted ? 0 : v * v).bitPattern))
    }
    /// Amplitude currently asked for (volume², or 0 while muted).
    public var targetGain: Float { Float(bitPattern: UInt32(truncatingIfNeeded: targetGainBits.load())) }

    public var isAttached: Bool { attachedFlag.load() != 0 }

    /// The mix's output AudioUnit and a counter that changes when it is replaced (see `MixBus`).
    public var outputAudioUnit: UnsafeMutableRawPointer? { bus?.outputAudioUnit }
    public var outputGeneration: UInt32 { bus?.outputGeneration ?? 0 }

    /// Join the mix (starting the output if this is the first channel). Safe to call again.
    public func attach() throws { try bus?.attach(self) }
    /// Leave the mix (stopping the output if this was the last channel).
    public func detach() { bus?.detach(self) }
}

/// Sums every attached channel into one stereo buffer, applies each channel's volume, and
/// soft-limits the result. `render` is real-time safe: no locks, allocation or logging.
public final class MixBus {
    public static let maxChannels = 8
    public let channels: [PlaybackChannel] = (0..<MixBus.maxChannels).map { PlaybackChannel(index: $0) }

    /// Starts/stops whatever pulls `render` (the audio engine, or a file writer). `startHook` runs
    /// on every `attach` and must be idempotent; `stopHook` when the last channel leaves.
    public var startHook: (() throws -> Void)?
    public var stopHook: (() -> Void)?

    private let lock = NSLock()
    private var claimed = Set<Int>()
    private let mutedFlag = AtomicUInt64()
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 8192
    /// Its own lock: the engine sets the unit while the bus lock may be held by `attach` (which starts the engine).
    private let outputLock = NSLock()
    private var outputUnit: UnsafeMutableRawPointer?
    private let generation = AtomicCounter()

    public init() {
        scratch = .allocate(capacity: scratchFrames * 2)
        scratch.initialize(repeating: 0, count: scratchFrames * 2)
        for c in channels { c.bus = self }
    }

    deinit { scratch.deallocate() }

    /// When true the mix is silence and no channel's ring is read (a paused app must keep running,
    /// not stop, or iOS suspends it).
    public var muted: Bool {
        get { mutedFlag.load() != 0 }
        set { mutedFlag.store(newValue ? 1 : 0) }
    }

    /// The output AudioUnit whose real-time workgroup the decode pumps join, and a counter that
    /// changes whenever it is replaced.
    public var outputAudioUnit: UnsafeMutableRawPointer? {
        outputLock.lock(); defer { outputLock.unlock() }
        return outputUnit
    }
    public var outputGeneration: UInt32 { generation.load() }
    public func setOutputUnit(_ unit: UnsafeMutableRawPointer?) {
        outputLock.lock(); outputUnit = unit; outputLock.unlock()
        generation.add(1)
    }

    // MARK: - Channels (not real-time)

    /// A free channel for a new source, or nil when all `maxChannels` are taken.
    public func claimChannel() -> PlaybackChannel? {
        lock.lock(); defer { lock.unlock() }
        guard let i = (0..<channels.count).first(where: { !claimed.contains($0) }) else { return nil }
        claimed.insert(i)
        let c = channels[i]
        c.volume = 1
        c.muted = false
        c.renderGain = 1
        c.starved = false
        return c
    }

    /// Give a channel back (detaching it if needed). Don't call while its decode pump may still write.
    public func release(_ channel: PlaybackChannel) {
        detach(channel)
        lock.lock(); claimed.remove(channel.index); lock.unlock()
    }

    public var attachedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return channels.reduce(0) { $0 + ($1.isAttached ? 1 : 0) }
    }

    func attach(_ c: PlaybackChannel) throws {
        lock.lock(); defer { lock.unlock() }
        try startHook?()
        c.attachedFlag.store(1)
    }

    func detach(_ c: PlaybackChannel) {
        lock.lock(); defer { lock.unlock() }
        guard c.isAttached else { return }
        c.attachedFlag.store(0)
        if !channels.contains(where: { $0.isAttached }) { stopHook?() }
    }

    /// Forget the largest-callback sizes (the output was just (re)started).
    public func resetCallbackStats() {
        for c in channels { _ = c.maxCallbackFrames.exchange(0) }
    }

    // MARK: - Render (real-time)

    /// Fill `left`/`right` with `frames` frames of the mix. Returns how many channels ran dry.
    @discardableResult
    public func render(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let n = frames
        let frameCount = UInt32(truncatingIfNeeded: n)
        var starvedCount = 0
        for c in channels where c.isAttached && frameCount > c.maxCallbackFrames.load() {
            _ = c.maxCallbackFrames.exchange(frameCount)
        }
        if muted || n > scratchFrames {
            // Output zeros but don't flag the buffer as silent: a paused app must keep
            // "playing" or iOS suspends it in the background and the stream is lost.
            l.update(repeating: 0, count: n); r.update(repeating: 0, count: n)
            for c in channels where c.isAttached { c.renderedFrames.add(UInt64(n)) }
            return 0
        }
        l.update(repeating: 0, count: n); r.update(repeating: 0, count: n)
        let want = n * 2
        for c in channels where c.isAttached {
            let got = c.ring.read(into: scratch, count: want)
            let gotFrames = got / 2
            // Ramp at the edges of a dropout (~1.3 ms) instead of cutting: an abrupt jump to or
            // from silence is what turns a gap into a pop.
            let ramp = 64
            if c.starved, gotFrames > 0 {
                let k = min(ramp, gotFrames)
                for i in 0..<k { let g = Float(i) / Float(k); scratch[2 * i] *= g; scratch[2 * i + 1] *= g }
                c.starved = false
            }
            if gotFrames < n {
                if !c.starved, gotFrames > 0 {
                    let k = min(ramp, gotFrames)
                    for i in 0..<k {
                        let g = Float(k - i) / Float(k + 1)
                        let at = gotFrames - k + i
                        scratch[2 * at] *= g; scratch[2 * at + 1] *= g
                    }
                }
                c.starved = true
                c.underruns.add(1)
                starvedCount += 1
            }
            let target = c.targetGain
            let from = c.renderGain
            c.renderGain = target
            if from == 1, target == 1 {
                for i in 0..<gotFrames { l[i] += scratch[2 * i]; r[i] += scratch[2 * i + 1] }
            } else if from != 0 || target != 0 {
                // Glide to the new volume over this callback instead of stepping (no zipper noise).
                let step = (target - from) / Float(n)
                for i in 0..<gotFrames {
                    let g = from + step * Float(i + 1)
                    l[i] += scratch[2 * i] * g; r[i] += scratch[2 * i + 1] * g
                }
            }
            c.renderedFrames.add(UInt64(n))
            c.wake.signal()
        }
        SoftLimiter.process(l, count: n)
        SoftLimiter.process(r, count: n)
        return starvedCount
    }
}
