import Foundation
import os
import HalltoneCore

private let log = Logger(subsystem: Constants.logSubsystem, category: "Pump")

/// High-priority thread that keeps the sink's hand-off ring topped up from the jitter buffer,
/// decoding, concealing and crossfading as the buffer directs.
final class DecodePump {
    let jitter: JitterBuffer
    private let decoder: AudioDecoder
    private let sink: PlaybackSink
    private let lock = NSLock()
    private var thread: Thread?
    private var running = false
    private let frame: Int
    /// Minimum decoded-ahead depth regardless of the output's callback size (~20 ms).
    private let baseLowWater: Int
    private var out: [Float]
    private var tmp: [Float]
    private var lastOut: [Float]
    private var cachedPos: UInt64?
    private var cached: [Float]
    /// Test hook: (samplePos, estimated uptime ns at which that frame reaches the sink) for
    /// every frame whose samplePos is a multiple of 4800.
    var onFrameScheduled: ((UInt64, UInt64) -> Void)?

    init(jitter: JitterBuffer, decoder: AudioDecoder, sink: PlaybackSink) {
        self.jitter = jitter
        self.decoder = decoder
        self.sink = sink
        frame = decoder.frameSamples
        // Keep ~20 ms (at least 2 frames) decoded ahead, or one full render callback plus a
        // frame when the output asks for bigger chunks (Bluetooth).
        baseLowWater = max(2 * frame, 960)
        let n = frame * Constants.channels
        out = [Float](repeating: 0, count: n)
        tmp = [Float](repeating: 0, count: n)
        lastOut = [Float](repeating: 0, count: n)
        cached = [Float](repeating: 0, count: n)
    }

    func start() {
        guard !running else { return }
        running = true
        _ = sink.underruns.exchange(0)
        let t = Thread { [self] in loop() }
        t.qualityOfService = .userInteractive
        t.name = "com.halltone.pump"
        thread = t
        t.start()
    }

    func stop() {
        running = false
        sink.wake.signal()
        thread = nil
    }

    func push(session: UInt32, samplePos: UInt64, payload: Data) {
        lock.lock()
        jitter.push(session: session, samplePos: samplePos, payload: payload, now: now())
        lock.unlock()
        sink.wake.signal()
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        jitter.flush(now: now())
        decoder.reset()
        cachedPos = nil
    }

    var stats: JitterBuffer.Stats {
        lock.lock(); defer { lock.unlock() }
        return jitter.stats
    }

    var recentGapMs: Double {
        lock.lock(); defer { lock.unlock() }
        return jitter.recentGapMs
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func loop() {
        let ch = Constants.channels
        let n = frame * ch
        while running {
            lock.lock()
            let t = now()
            let under = sink.underruns.exchange(0)
            if under > 0, jitter.stats.primed { jitter.reportUnderrun(now: t) }
            var wrote = false
            let callback = Int(sink.maxCallbackFrames.load())
            let lowWaterSamples = max(baseLowWater, callback + frame)
            while running, sink.ring.availableToRead < lowWaterSamples * ch {
                let ahead = sink.ring.availableToRead / ch
                let pull = jitter.pull(playoutAhead: ahead, now: t)
                if case .wait = pull { break }
                produce(pull)
                if let hook = onFrameScheduled, let pos = pull.samplePos, pos % 4800 == 0 {
                    let aheadNs = UInt64(Double(ahead) / Constants.sampleRate * 1e9)
                    hook(pos, DispatchTime.now().uptimeNanoseconds + aheadNs)
                }
                softLimit(&out)
                out.withUnsafeBufferPointer { sink.ring.write($0.baseAddress!, count: n) }
                for i in 0..<n { lastOut[i] = out[i] }
                wrote = true
            }
            lock.unlock()
            if !wrote { _ = sink.wake.wait(timeout: .now() + .milliseconds(20)) }
        }
    }

    private func decodeInto(_ dst: inout [Float], _ payload: Data, pos: UInt64) {
        if let c = cachedPos, c == pos {
            for i in 0..<dst.count { dst[i] = cached[i] }
            cachedPos = nil
            return
        }
        payload.withUnsafeBytes { raw in
            dst.withUnsafeMutableBufferPointer { _ = decoder.decode(raw, into: $0.baseAddress!) }
        }
    }

    private func produce(_ pull: JitterBuffer.Pull) {
        let n = frame * Constants.channels
        switch pull {
        case .wait:
            break
        case .frame(let pos, let payload):
            decodeInto(&out, payload, pos: pos)
        case .conceal(_, let next):
            var ok = false
            if let next {
                ok = next.withUnsafeBytes { raw in out.withUnsafeMutableBufferPointer { decoder.decodeFEC(nextPayload: raw, into: $0.baseAddress!) } }
            }
            if !ok { out.withUnsafeMutableBufferPointer { decoder.conceal(into: $0.baseAddress!) } }
        case .dropped(let pos, let dropped, let nextPos, let next):
            // Time-compress two frames into one with a linear crossfade.
            decodeInto(&tmp, dropped, pos: pos)
            decodeInto(&out, next, pos: nextPos)
            crossfade(from: tmp, to: &out)
        case .duplicate(let nextPos, let next):
            // Stretch: emit a bridge from the last output into the upcoming frame, keep it queued.
            decodeInto(&cached, next, pos: nextPos)
            cachedPos = nextPos
            for i in 0..<n { out[i] = cached[i] }
            crossfade(from: lastOut, to: &out)
        }
    }

    /// Program material often peaks at full scale and Opus decoding can overshoot slightly; hard
    /// clipping at the output sounds harsh. Pass everything below 0.9 untouched and bend the rest
    /// smoothly toward ±1.
    private func softLimit(_ x: inout [Float]) {
        let knee: Float = 0.9
        let range: Float = 1 - knee
        for i in 0..<x.count {
            let v = x[i]
            let a = abs(v)
            if a > knee {
                let over = (a - knee) / range
                let shaped = knee + range * (over / (1 + over))
                x[i] = v < 0 ? -shaped : shaped
            }
        }
    }

    private func crossfade(from a: [Float], to b: inout [Float]) {
        let ch = Constants.channels
        for f in 0..<frame {
            let g = Float(f) / Float(frame - 1)
            for c in 0..<ch {
                let i = f * ch + c
                b[i] = a[i] * (1 - g) + b[i] * g
            }
        }
    }
}
