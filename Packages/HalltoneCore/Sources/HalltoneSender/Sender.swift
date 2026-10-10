#if os(macOS)
import Foundation
import AVFoundation
import CoreAudio
import os
import HalltoneCore

private let log = Logger(subsystem: Constants.logSubsystem, category: "Sender")

/// Listens for subscribers on a UDP socket, advertises via Bonjour, captures system audio only
/// while at least one subscriber is alive, and fans AUDIO packets out to all of them.
public final class Sender {
    public struct Config {
        public var port: UInt16 = Constants.defaultPort
        public var codec: CodecID = .pcm16
        /// nil accepts any pairing code.
        public var pairingCode: UInt32?
        public var advertise = true
        public var macName: String = Host.current().localizedName ?? "Mac"
        /// Test hooks (CLI): randomly drop / delay outgoing audio packets.
        public var simulatedLoss: Double = 0
        public var simulatedJitterMs: Double = 0
        public init() {}
    }

    /// Test hook: (samplePos, uptime ns) for every packet whose samplePos is a multiple of 4800.
    public var onPacketSent: ((UInt64, UInt64) -> Void)?

    public struct SubscriberInfo: Equatable, Identifiable {
        public var id: String
        public var name: String
        public var lastSeen: Date
        public var bufferMs: Int
        public var lossPermille: Int
    }

    public struct Stats: Equatable {
        public var listening = false
        public var capturing = false
        public var subscribers: [SubscriberInfo] = []
        public var packetsPerSecond = 0
        public var kilobitsPerSecond = 0
        public var captureError: String?
        public init() {}
    }

    public var onStats: ((Stats) -> Void)?
    /// Carries out a CONTROL from a phone; returns false if it couldn't (e.g. permission missing).
    public var onControl: ((ControlCommand) -> Bool)?
    /// Whether CONTROL commands can currently be carried out. nil: don't send STATUS at all.
    public var controlsAvailable: (() -> Bool)?
    private var lastControlsFlag: Bool?
    private var statusTicks = 0

    public private(set) var stats = Stats()
    public let config: Config

    private final class Subscriber {
        let address: sockaddr_storage
        var name: String
        var lastSeen = Date()
        var bufferMs = 0
        var lossPermille = 0
        init(address: sockaddr_storage, name: String) { self.address = address; self.name = name }
    }

    private let makeSource: () -> AudioSource
    private let queue = DispatchQueue(label: "com.halltone.sender")
    private var socket: UDPSocket?
    private var advertiser: BonjourAdvertiser?
    private var receiveThread: Thread?
    private var running = false
    private let lock = NSLock()
    private var subscribers: [String: Subscriber] = [:]
    /// Snapshot of subscriber addresses for the encode thread (rebuilt under `lock` on change).
    private var targets: [sockaddr_storage] = []
    private let session = UInt32.random(in: 1...UInt32.max)
    private var audioSeq: UInt32 = 0
    private var controlSeq: UInt32 = 0
    private var samplePos: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var lastPublished: Stats?

    // Capture + encode.
    private let captureQueue = DispatchQueue(label: "com.halltone.capture")
    private var source: AudioSource?
    private var capturing = false
    private let captureRing = RingBuffer(capacity: 1 << 17)
    private let ring48 = RingBuffer(capacity: 1 << 17)
    private var encodeThread: Thread?
    private var encoding = false
    private let wake = DispatchSemaphore(value: 0)
    /// Bumped whenever `source` is swapped under a running encoder (output device change), so
    /// the encode thread re-reads the capture format.
    private let sourceGeneration = AtomicCounter()
    private let sourceLock = NSLock()
    private var activeSource: AudioSource? {
        sourceLock.lock(); defer { sourceLock.unlock() }
        return source
    }
    private let packetsCounter = AtomicCounter()
    private let bytesCounter = AtomicCounter()
    private var deviceListenerInstalled = false

    public init(config: Config, source: @escaping () -> AudioSource) {
        self.config = config
        self.makeSource = source
    }

    // MARK: - Lifecycle

    public func start() throws {
        let sock = try UDPSocket(port: config.port)
        socket = sock
        running = true
        if config.advertise {
            advertiser = BonjourAdvertiser(name: config.macName, port: config.port,
                                           txtValues: ["name": config.macName, "v": "1"], queue: queue)
        }
        let t = Thread { [self] in receiveLoop(sock) }
        t.qualityOfService = .userInitiated
        t.name = "com.halltone.recv"
        receiveThread = t
        t.start()
        log.notice("listening on udp/\(self.config.port)")
        stats.listening = true
        publish()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        installDeviceListener()
    }

    public func stop() {
        queue.sync {
            lock.lock()
            let subs = Array(subscribers.values)
            subscribers.removeAll()
            targets = []
            lock.unlock()
            for s in subs { sendControl(.bye, to: s.address) }
            timer?.cancel(); timer = nil
            advertiser = nil
            running = false
            socket?.shutdownForClose()
            stats = Stats()
            lastPublished = nil
            publish()
        }
        stopCapture()
        captureQueue.sync {}
        receiveThread = nil
        socket = nil
    }

    // MARK: - Receive

    private func receiveLoop(_ sock: UDPSocket) {
        let cap = 2048
        let buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
        defer { buf.deallocate() }
        var from = sockaddr_storage()
        while running {
            let n = sock.receive(into: buf, capacity: cap, from: &from)
            if n < 0 { if running { log.error("recvfrom failed: \(errno)") }; break }
            if n == 0 { continue }
            let data = Data(bytesNoCopy: buf, count: n, deallocator: .none)
            guard let packet = Packet.decode(data) else { continue }
            handle(packet, from: from)
        }
    }

    private func handle(_ packet: Packet, from address: sockaddr_storage) {
        let key = UDPSocket.describe(address)
        switch packet.message {
        case .subscribe(let code, let name):
            if let required = config.pairingCode, required != code {
                log.notice("rejecting \(name, privacy: .public): bad pairing code")
                sendControl(.subscribeNak(reason: NakReason.badPairingCode.rawValue), to: address)
                return
            }
            let frame = CodecFactory.frameSamples(for: config.codec)
            let ack = Message.subscribeAck(codec: config.codec, sampleRate: UInt32(Constants.sampleRate),
                                           channels: UInt8(Constants.channels), frameSamples: UInt16(frame),
                                           macName: config.macName)
            lock.lock()
            if let existing = subscribers[key] {
                existing.name = name
                existing.lastSeen = Date()
            } else {
                subscribers[key] = Subscriber(address: address, name: name)
                targets = subscribers.values.map(\.address)
                log.notice("subscriber joined: \(name, privacy: .public) @ \(key, privacy: .public)")
            }
            lock.unlock()
            sendControl(ack, to: address)
            sendStatus(to: [address])
            startCaptureIfNeeded()
            queue.async { self.publish() }
        case .keepalive(_, let loss, let buf):
            lock.lock()
            if let s = subscribers[key] {
                s.lastSeen = Date(); s.lossPermille = Int(loss); s.bufferMs = Int(buf)
            }
            lock.unlock()
        case .bye:
            remove(key: key, reason: "bye")
        case .control(let cmd):
            let ok = onControl?(cmd) ?? false
            if !ok { sendStatus(to: [address], lastControlFailed: true) }
        default:
            break
        }
    }

    private func remove(key: String, reason: String) {
        lock.lock()
        let removed = subscribers.removeValue(forKey: key)
        targets = subscribers.values.map(\.address)
        let empty = subscribers.isEmpty
        lock.unlock()
        if let removed {
            log.notice("subscriber left: \(removed.name, privacy: .public) (\(reason, privacy: .public))")
            if empty { stopCapture() }
            queue.async { self.publish() }
        }
    }

    private func sendControl(_ message: Message, to address: sockaddr_storage) {
        guard let socket else { return }
        controlSeq &+= 1
        let data = Packet(seq: controlSeq, session: session, message: message).encode()
        data.withUnsafeBytes { raw in
            if let p = raw.baseAddress { socket.send(p, raw.count, to: address) }
        }
    }

    /// STATUS to the given subscribers (or all). Cheap; safe to call from any queue.
    private func sendStatus(to addresses: [sockaddr_storage]? = nil, lastControlFailed: Bool = false) {
        guard let available = controlsAvailable else { return }
        var flags: StatusFlags = []
        if available() { flags.insert(.controlsAvailable) }
        if lastControlFailed { flags.insert(.lastControlFailed) }
        let targetsNow: [sockaddr_storage]
        if let addresses { targetsNow = addresses } else { lock.lock(); targetsNow = targets; lock.unlock() }
        for a in targetsNow { sendControl(.status(flags: flags), to: a) }
    }

    private func tick() {
        // STATUS: immediately when the permission flips, otherwise every 5 s (UDP may drop it).
        if let available = controlsAvailable?() {
            statusTicks += 1
            if available != lastControlsFlag || statusTicks % 5 == 0 {
                if available != lastControlsFlag, lastControlsFlag != nil {
                    log.notice("controls available: \(available)")
                }
                lastControlsFlag = available
                sendStatus()
            }
        }
        let cutoff = Date().addingTimeInterval(-Constants.subscriberTimeout)
        lock.lock()
        let expired = subscribers.filter { $0.value.lastSeen < cutoff }
        lock.unlock()
        for (key, _) in expired { remove(key: key, reason: "timeout") }
        stats.packetsPerSecond = Int(packetsCounter.exchange(0))
        stats.kilobitsPerSecond = Int(bytesCounter.exchange(0)) * 8 / 1000
        publish()
    }

    private func publish() {
        lock.lock()
        stats.subscribers = subscribers.map { key, s in
            SubscriberInfo(id: key, name: s.name, lastSeen: s.lastSeen, bufferMs: s.bufferMs, lossPermille: s.lossPermille)
        }.sorted { $0.name < $1.name }
        lock.unlock()
        stats.capturing = capturing
        if stats != lastPublished {
            lastPublished = stats
            onStats?(stats)
        }
    }

    // MARK: - Capture

    private func startCaptureIfNeeded() {
        captureQueue.async { [self] in
            guard source == nil else { return }
            let src = makeSource()
            src.dataAvailable = wake
            captureRing.reset()
            ring48.reset()
            // Start the encoder first: it paces out silence until the tap delivers, and tap start
            // can take a moment (first-run permission prompt).
            sourceLock.lock(); source = src; sourceLock.unlock()
            capturing = true
            encoding = true
            let t = Thread { [self] in encodeLoop() }
            t.qualityOfService = .userInteractive
            t.name = "com.halltone.encode"
            encodeThread = t
            t.start()
            do {
                try src.start(into: captureRing)
            } catch {
                log.error("capture failed: \(String(describing: error), privacy: .public)")
                encoding = false
                wake.signal()
                encodeThread = nil
                sourceLock.lock(); source = nil; sourceLock.unlock()
                capturing = false
                queue.async { self.stats.captureError = "\(error)"; self.publish() }
                return
            }
            sourceGeneration.add(1)
            log.notice("capture started (\(src.format?.sampleRate ?? 0) Hz)")
            queue.async { self.stats.captureError = nil; self.publish() }
        }
    }

    private func stopCapture() {
        captureQueue.async { [self] in
            guard source != nil else { return }
            encoding = false
            wake.signal()
            encodeThread = nil
            source?.stop()
            sourceLock.lock(); source = nil; sourceLock.unlock()
            capturing = false
            log.notice("capture stopped")
            queue.async { self.publish() }
        }
    }

    /// Test hook: exercise the output-device-change path without touching system audio settings.
    public func simulateOutputDeviceChange() { restartCapture() }

    /// Output device changed (e.g. AirPods moved). Swap the tap underneath the running encoder:
    /// the encoder keeps pacing out silence during the swap, so subscribers see no gap and
    /// samplePos stays continuous.
    private func restartCapture() {
        captureQueue.async { [self] in
            guard let old = source else { return }
            log.notice("default output device changed; swapping tap")
            old.stop()
            let src = makeSource()
            src.dataAvailable = wake
            do {
                try src.start(into: captureRing)
            } catch {
                log.error("capture restart failed: \(String(describing: error), privacy: .public)")
                // Keep the encoder alive (silence) and retry once shortly.
                sourceLock.lock(); source = src; sourceLock.unlock()
                captureQueue.asyncAfter(deadline: .now() + 1) { [self] in restartCapture() }
                return
            }
            sourceLock.lock(); source = src; sourceLock.unlock()
            sourceGeneration.add(1)
            wake.signal()
            log.notice("tap swapped (\(src.format?.sampleRate ?? 0) Hz)")
        }
    }

    private func installDeviceListener() {
        guard !deviceListenerInstalled else { return }
        deviceListenerInstalled = true
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { [weak self] _, _ in
            self?.restartCapture()
        }
    }

    /// Encode thread: drains the capture ring, resamples to 48 kHz if needed, encodes each frame
    /// straight into a preallocated datagram and sends it to every subscriber with sendto().
    private func encodeLoop() {
        let encoder: AudioEncoder
        switch config.codec {
        case .pcm16:
            encoder = PCM16Encoder()
        case .opus:
            do { encoder = try OpusEncoder() } catch {
                log.error("opus encoder unavailable (\(error)); falling back to PCM16")
                encoder = PCM16Encoder()
            }
        }
        let frame = encoder.frameSamples
        let ch = Constants.channels
        let fmt48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Constants.sampleRate, channels: 2, interleaved: true)!
        var needsResample = false
        var converter: AVAudioConverter?
        var inBuf: AVAudioPCMBuffer?
        var outBuf: AVAudioPCMBuffer?
        var formatResolved = false
        var srcRing = captureRing
        let pcm = UnsafeMutablePointer<Float>.allocate(capacity: frame * ch)
        let silence = UnsafeMutablePointer<Float>.allocate(capacity: frame * ch)
        silence.initialize(repeating: 0, count: frame * ch)
        let datagram = UnsafeMutablePointer<UInt8>.allocate(capacity: Packet.audioOverhead + encoder.maxPayloadBytes)
        defer { pcm.deallocate(); silence.deallocate(); datagram.deallocate() }

        // The global tap only runs IO while some process is actually playing audio. While it is
        // idle we keep the stream alive with wall-clock-paced silent frames.
        let frameDur = Double(frame) / Constants.sampleRate
        let idleGap = 0.03
        var lastRealFrame = Date.distantPast
        var silenceStart: Date?
        var silenceSent = 0

        func sendFrame(_ samples: UnsafePointer<Float>) {
            let bytes = encoder.encode(samples, into: datagram + Packet.audioOverhead)
            guard bytes > 0 else { return }
            audioSeq &+= 1
            Packet.writeAudioHeader(into: datagram, seq: audioSeq, session: session, samplePos: samplePos,
                                    codec: encoder.codec, payloadLength: bytes)
            let pos = samplePos
            samplePos += UInt64(frame)
            fanOut(datagram, Packet.audioOverhead + bytes, samplePos: pos)
        }

        var seenGeneration = sourceGeneration.load()
        while encoding {
            let gen = sourceGeneration.load()
            if gen != seenGeneration { seenGeneration = gen; formatResolved = false }
            if !formatResolved, let nativeFormat = activeSource?.format {
                formatResolved = true
                needsResample = nativeFormat.sampleRate != Constants.sampleRate
                if needsResample {
                    converter = AVAudioConverter(from: nativeFormat, to: fmt48)
                    inBuf = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: 1024)
                    outBuf = AVAudioPCMBuffer(pcmFormat: fmt48, frameCapacity: 2048)
                    srcRing = ring48
                } else {
                    converter = nil; inBuf = nil; outBuf = nil
                    srcRing = captureRing
                }
            }
            if needsResample, let converter, let inBuf, let outBuf {
                let avail = captureRing.availableToRead / ch
                if avail >= 256 {
                    let n = min(avail, 1024)
                    let got = inBuf.floatChannelData!.pointee.withMemoryRebound(to: Float.self, capacity: n * ch) {
                        captureRing.read(into: $0, count: n * ch)
                    }
                    inBuf.frameLength = AVAudioFrameCount(got / ch)
                    var fed = false
                    var err: NSError?
                    outBuf.frameLength = 0
                    let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
                        if fed { outStatus.pointee = .noDataNow; return nil }
                        fed = true; outStatus.pointee = .haveData; return inBuf
                    }
                    if status != .error, outBuf.frameLength > 0 {
                        ring48.write(outBuf.floatChannelData!.pointee, count: Int(outBuf.frameLength) * ch)
                    }
                }
            }
            var sentAny = false
            while encoding, srcRing.availableToRead >= frame * ch {
                srcRing.read(into: pcm, count: frame * ch)
                sendFrame(pcm)
                sentAny = true
                lastRealFrame = Date()
                silenceStart = nil
            }
            if !sentAny {
                let now = Date()
                if now.timeIntervalSince(lastRealFrame) > idleGap {
                    if silenceStart == nil { silenceStart = now; silenceSent = 0 }
                    let due = Int(now.timeIntervalSince(silenceStart!) / frameDur)
                    while encoding, silenceSent < due {
                        sendFrame(silence)
                        silenceSent += 1
                    }
                }
                _ = wake.wait(timeout: .now() + .milliseconds(10))
            }
        }
    }

    private func fanOut(_ ptr: UnsafePointer<UInt8>, _ len: Int, samplePos: UInt64) {
        if samplePos % 4800 == 0, let hook = onPacketSent { hook(samplePos, DispatchTime.now().uptimeNanoseconds) }
        packetsCounter.add(1)
        bytesCounter.add(UInt32(len))
        if config.simulatedLoss > 0, Double.random(in: 0..<1) < config.simulatedLoss { return }
        if config.simulatedJitterMs > 0 {
            let copy = Data(bytes: ptr, count: len)
            let delay = Double.random(in: 0..<config.simulatedJitterMs) / 1000
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                copy.withUnsafeBytes { raw in if let p = raw.baseAddress { fanOutNow(p, raw.count) } }
            }
        } else {
            fanOutNow(ptr, len)
        }
    }

    @inline(__always)
    private func fanOutNow(_ ptr: UnsafeRawPointer, _ len: Int) {
        guard let socket else { return }
        lock.lock()
        let addrs = targets
        lock.unlock()
        for a in addrs { socket.send(ptr, len, to: a) }
    }
}
#endif
