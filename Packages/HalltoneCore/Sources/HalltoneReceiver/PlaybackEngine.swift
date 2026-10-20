import Foundation
import AVFoundation
import os
import HalltoneCore

private let log = Logger(subsystem: Constants.logSubsystem, category: "Playback")

/// AVAudioEngine → AVAudioSourceNode pulling from the hand-off ring. The render block does no
/// allocation, locking or logging; it copies and de-interleaves.
public final class PlaybackEngine: PlaybackSink {
    public let ring = RingBuffer(capacity: 1 << 17) // ~1.3 s stereo
    public let underruns = AtomicCounter()
    public let renderedFrames = AtomicUInt64()
    public let wake = DispatchSemaphore(value: 0)
    public let maxCallbackFrames = AtomicCounter()
    private let outputLock = NSLock()
    private var outputUnit: UnsafeMutableRawPointer?
    private let generation = AtomicCounter()
    public var outputAudioUnit: UnsafeMutableRawPointer? {
        outputLock.lock(); defer { outputLock.unlock() }
        return outputUnit
    }
    public var outputGeneration: UInt32 { generation.load() }

    public private(set) var engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 8192
    private var running = false
    /// When false the render block outputs silence without touching the ring (used while paused).
    public var muted = false

    public init() {
        scratch = .allocate(capacity: scratchFrames * 2)
        scratch.initialize(repeating: 0, count: scratchFrames * 2)
    }

    deinit { scratch.deallocate() }

    public func start() throws {
        guard !running else { return }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: Constants.sampleRate, channels: 2)!
        let ring = self.ring, underruns = self.underruns, rendered = self.renderedFrames, wake = self.wake
        let maxFrames = self.maxCallbackFrames
        _ = maxFrames.exchange(0)
        let scratch = self.scratch, scratchFrames = self.scratchFrames
        let node = AVAudioSourceNode(format: fmt) { [weak self] isSilence, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            let frames = Int(frameCount)
            if frameCount > maxFrames.load() { _ = maxFrames.exchange(frameCount) }
            guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            if self?.muted == true || frames > scratchFrames {
                // Output zeros but don't flag the buffer as silent: a paused app must keep
                // "playing" or iOS suspends it in the background and the stream is lost.
                l.update(repeating: 0, count: frames); r.update(repeating: 0, count: frames)
                rendered.add(UInt64(frames))
                return noErr
            }
            let want = frames * 2
            let got = ring.read(into: scratch, count: want)
            let gotFrames = got / 2
            var i = 0
            while i < gotFrames { l[i] = scratch[2 * i]; r[i] = scratch[2 * i + 1]; i += 1 }
            if gotFrames < frames {
                (l + gotFrames).update(repeating: 0, count: frames - gotFrames)
                (r + gotFrames).update(repeating: 0, count: frames - gotFrames)
                underruns.add(1)
            }
            rendered.add(UInt64(frames))
            wake.signal()
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        try engine.start()
        outputLock.lock()
        outputUnit = engine.outputNode.audioUnit.map { UnsafeMutableRawPointer($0) }
        outputLock.unlock()
        generation.add(1)
        sourceNode = node
        running = true
        log.info("engine started; output \(self.engine.outputNode.outputFormat(forBus: 0).sampleRate) Hz")
    }

    public func stop() {
        guard running else { return }
        engine.stop()
        if let n = sourceNode { engine.detach(n) }
        sourceNode = nil
        running = false
        log.info("engine stopped")
    }

    /// Rebuild with a fresh AVAudioEngine after a route change, interruption or media-services
    /// reset. A stale engine can refuse to start after the output route changed.
    public func restart() throws {
        stop()
        engine = AVAudioEngine()
        try start()
    }
}
