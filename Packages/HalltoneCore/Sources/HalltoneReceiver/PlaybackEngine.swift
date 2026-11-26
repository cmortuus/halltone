import Foundation
import AVFoundation
import os
import HalltoneCore

private let log = Logger(subsystem: Constants.logSubsystem, category: "Playback")

/// One AVAudioEngine with a single AVAudioSourceNode that pulls the `MixBus`: every source's
/// hand-off ring is summed, scaled by its volume and soft-limited inside the render block, so
/// sources join and leave the mix without the engine restarting. The render block does no
/// allocation, locking or logging; it copies and de-interleaves.
///
/// (One node for all sources rather than one per source: the limiter has to see the sum, and a
/// node per source would need a custom audio unit after the main mixer to do that.)
public final class PlaybackEngine {
    public let bus = MixBus()
    public private(set) var engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var running = false
    /// start/stop/restart run from receiver queues (a source joining) and the main thread (route changes).
    private let engineLock = NSRecursiveLock()
    /// When true the render block outputs silence without touching the rings (used while paused).
    public var muted: Bool {
        get { bus.muted }
        set { bus.muted = newValue }
    }

    public init() {
        bus.startHook = { [unowned self] in try self.start() }
        bus.stopHook = { [unowned self] in self.stop() }
    }

    public func start() throws {
        engineLock.lock(); defer { engineLock.unlock() }
        guard !running else { return }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: Constants.sampleRate, channels: 2)!
        let bus = self.bus
        bus.resetCallbackStats()
        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            bus.render(left: l, right: r, frames: Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // An engine made before iOS's audio server restarted (media services reset while we
            // sat idle) can never start again (-50 initializing the output). Try a fresh one.
            log.notice("engine start failed (\(error)); retrying with a new engine")
            engine.detach(node)
            engine = AVAudioEngine()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            engine.prepare()
            try engine.start()
        }
        bus.setOutputUnit(engine.outputNode.audioUnit.map { UnsafeMutableRawPointer($0) })
        sourceNode = node
        running = true
        log.info("engine started; output \(self.engine.outputNode.outputFormat(forBus: 0).sampleRate) Hz")
    }

    public func stop() {
        engineLock.lock(); defer { engineLock.unlock() }
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
        engineLock.lock(); defer { engineLock.unlock() }
        stop()
        engine = AVAudioEngine()
        try start()
    }

    /// Drop the engine without starting a new one (used while idle); the next start() builds it.
    public func discardEngine() {
        engineLock.lock(); defer { engineLock.unlock() }
        stop()
        engine = AVAudioEngine()
    }
}
