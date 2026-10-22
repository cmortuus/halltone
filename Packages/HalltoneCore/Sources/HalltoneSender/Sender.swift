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
        /// Wi-Fi power-save style bursts: every `simulatedBurstEveryMs`, hold all packets for
        /// `simulatedBurstMs` and then release them at once.
        public var simulatedBurstMs: Double = 0
        public var simulatedBurstEveryMs: Double = 2000
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
    /// Called on the sender's queue when "keep headphones on the phone" turns on or off: on while
    /// any subscribed phone asks for it.
    public var onHoldHeadphones: ((Bool) -> Void)?
    /// Whether this Mac can keep headphones on the phone (reported in STATUS).
    public var canHoldHeadphones: (() -> Bool)?
    /// Whether someone is using this Mac right now (reported in STATUS; sent at once on change).
    public var userAtMac: (() -> Bool)?
    /// Input in the last ~20 s (reported in STATUS; sent at once on change).
    public var userInputRecent: (() -> Bool)?
    private var lastUserAtMac: Bool?
    private var lastInputRecent: Bool?
    private var lastPlaying = false

    /// Captured audio was audible within the last 2 s.
    public func isPlaying() -> Bool {
        DispatchTime.now().uptimeNanoseconds &- lastAudibleUptimeNs.load() < 2_000_000_000
    }
    private var holdingHeadphones = false
    /// Hold requests from phones subscribed to another Mac (address → last request).
    private var remoteHolds: [String: Date] = [:]
    /// Unknown addresses that said they're paused, so their hold requests aren't remote holds.
    private var pausedStrangers: [String: Date] = [:]
    /// Uptime (ns) of the last captured frame that wasn't near-silent. Lets the app tell whether
    /// something was playing, and whether it stopped (e.g. paused when headphones disconnected).
    public let lastAudibleUptimeNs = AtomicUInt64()
    private var lastControlsFlag: Bool?
    private var statusTicks = 0
    private var nudgeLogTicks = 0
    /// The last ~2.5 s of audio datagrams, for RESEND.
    private let history = DatagramHistory(slots: 256)
    private let resentCounter = AtomicCounter()
    /// Audio sends the kernel refused (EHOSTDOWN after an ARP miss, ENOBUFS, …) and the last errno.
    private let sendFailures = AtomicCounter()
    private let lastSendErrno = AtomicCounter()

    public private(set) var stats = Stats()
    public let config: Config

    private final class Subscriber {
        let address: sockaddr_storage
        var name: String
        var lastSeen = Date()
        var bufferMs = 0
        var lossPermille = 0
        var holdHeadphones = false
        var deviceID: String?
        /// The phone said it isn't playing (headphones out). Kept subscribed, not captured for.
        var paused = false
        /// Phone → Mac NUDGE timing (sent every 20 ms): shows whether the phone kept sending
        /// while its audio arrived in bursts (diagnostics, logged every 10 s).
        var lastNudge: TimeInterval?
        var maxNudgeGapMs = 0.0
        var nudges = 0
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
                                           txtValues: ["name": config.macName, "v": "1", "port": String(config.port)],
                                           queue: queue)
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
        case .subscribe(let code, let name, let deviceID):
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
            remoteHolds[key] = nil
            if let existing = subscribers[key] {
                existing.name = name
                existing.lastSeen = Date()
            } else if let deviceID, let (oldKey, old) = subscribers.first(where: { $0.value.deviceID == deviceID }) {
                // Same phone, new address (Wi-Fi ↔ VPN): move it, keeping its state, instead of
                // adding a second subscriber and timing the old one out.
                subscribers.removeValue(forKey: oldKey)
                let moved = Subscriber(address: address, name: name)
                moved.deviceID = deviceID
                moved.holdHeadphones = old.holdHeadphones
                moved.paused = old.paused
                subscribers[key] = moved
                targets = subscribers.values.map(\.address)
                log.notice("subscriber moved: \(name, privacy: .public) \(oldKey, privacy: .public) → \(key, privacy: .public)")
            } else {
                let s = Subscriber(address: address, name: name)
                s.deviceID = deviceID
                subscribers[key] = s
                targets = subscribers.values.map(\.address)
                log.notice("subscriber joined: \(name, privacy: .public) @ \(key, privacy: .public)")
            }
            lock.unlock()
            sendControl(ack, to: address)
            sendStatus(to: [address])
            updateCapture()
            queue.async { self.publish() }
        case .keepalive(_, let loss, let buf):
            lock.lock()
            let s = subscribers[key]
            if let s { s.lastSeen = Date(); s.lossPermille = Int(loss); s.bufferMs = Int(buf) }
            lock.unlock()
            // A phone that still thinks it's subscribed (this app restarted, or timed it out
            // while it was paused and sending nothing we'd miss): have it subscribe again.
            if s == nil { sendControl(.subscribeNak(reason: NakReason.notSubscribed.rawValue), to: address) }
        case .nudge:
            let t = ProcessInfo.processInfo.systemUptime
            lock.lock()
            if let s = subscribers[key] {
                if let last = s.lastNudge { s.maxNudgeGapMs = max(s.maxNudgeGapMs, (t - last) * 1000) }
                s.lastNudge = t
                s.nudges += 1
            }
            lock.unlock()
        case .resend(let positions):
            guard let socket else { break }
            lock.lock(); let known = subscribers[key] != nil; lock.unlock()
            guard known else { break }
            var sent = 0
            for p in positions {
                if history.withDatagram(samplePos: p, { socket.send($0, $1, to: address) }) { sent += 1 }
            }
            resentCounter.add(UInt32(sent))
        case .bye:
            remove(key: key, reason: "bye")
        case .control(let cmd) where !cmd.isMediaKey:
            lock.lock()
            if subscribers[key] == nil, cmd == .notListening {
                // A paused phone we don't know (it holds only while listening), not one guarding
                // from another Mac: never hold for it.
                remoteHolds[key] = nil
                pausedStrangers[key] = Date()
            } else if subscribers[key] == nil, cmd == .holdHeadphonesOn || cmd == .holdHeadphonesOff,
                      pausedStrangers[key].map({ Date().timeIntervalSince($0) > 15 }) ?? true {
                // A phone listening to another Mac: macOS automatic switching lets this Mac take
                // its AirPods whenever it plays something, so guard them here too. No pairing
                // code: LAN only, and the worst it can do is drop this Mac's Bluetooth
                // headphones (rate-limited by the guard). Expires 15 s after the last request.
                if cmd == .holdHeadphonesOn { remoteHolds[key] = Date() } else { remoteHolds[key] = nil }
            }
            if let s = subscribers[key] {
                switch cmd {
                case .holdHeadphonesOn, .holdHeadphonesOff: s.holdHeadphones = cmd == .holdHeadphonesOn
                case .listening, .notListening:
                    let paused = cmd == .notListening
                    if s.paused != paused { log.notice("\(s.name, privacy: .public) \(paused ? "paused" : "listening again", privacy: .public)") }
                    s.paused = paused
                default: break
                }
            }
            lock.unlock()
            updateHoldHeadphones()
            updateCapture()
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
        updateHoldHeadphones()
        if let removed {
            log.notice("subscriber left: \(removed.name, privacy: .public) (\(reason, privacy: .public))")
            if empty { stopCapture() } else { updateCapture() }
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
        if canHoldHeadphones?() == true { flags.insert(.canHoldHeadphones) }
        if userAtMac?() == true { flags.insert(.userAtMac) }
        if userInputRecent?() == true { flags.insert(.userInputRecent) }
        flags.insert(.explicitPlayPause)
        if isPlaying() { flags.insert(.macPlaying) }
        let targetsNow: [sockaddr_storage]
        if let addresses { targetsNow = addresses } else { lock.lock(); targetsNow = targets; lock.unlock() }
        for a in targetsNow { sendControl(.status(flags: flags), to: a) }
    }

    /// Capture only while some phone is actually playing: a paused phone (headphones out) keeps
    /// its subscription, but the Mac stops muting its speakers and sending audio.
    private func updateCapture() {
        lock.lock()
        let anyListening = subscribers.values.contains { !$0.paused }
        let anySubscriber = !subscribers.isEmpty
        lock.unlock()
        if anyListening { startCaptureIfNeeded() } else if anySubscriber { stopCapture() }
    }

    /// Some subscribed phone is playing (not paused). Only then should this Mac press play when
    /// its headphones leave; a remote hold alone mustn't start media here.
    public var hasListeningSubscriber: Bool {
        lock.lock(); defer { lock.unlock() }
        return subscribers.values.contains { !$0.paused }
    }

    private func updateHoldHeadphones() {
        lock.lock()
        let cutoff = Date().addingTimeInterval(-15)
        remoteHolds = remoteHolds.filter { $0.value > cutoff }
        pausedStrangers = pausedStrangers.filter { $0.value > cutoff }
        let want = subscribers.values.contains { $0.holdHeadphones && !$0.paused } || !remoteHolds.isEmpty
        lock.unlock()
        queue.async { [self] in
            guard want != holdingHeadphones else { return }
            holdingHeadphones = want
            log.notice("keep headphones on phone: \(want)")
            onHoldHeadphones?(want)
        }
    }

    private func tick() {
        // STATUS: immediately when the permission flips, otherwise every 5 s (UDP may drop it).
        if let available = controlsAvailable?() {
            statusTicks += 1
            let atMac = userAtMac?()
            let inputRecent = userInputRecent?()
            let playing = isPlaying()
            let presenceChanged = atMac != lastUserAtMac || inputRecent != lastInputRecent || playing != lastPlaying
            lastInputRecent = inputRecent
            lastPlaying = playing
            if presenceChanged, lastUserAtMac != nil {
                log.notice("user at Mac: \(atMac ?? false)")
            }
            lastUserAtMac = atMac
            if available != lastControlsFlag || presenceChanged || statusTicks % 5 == 0 {
                if available != lastControlsFlag, lastControlsFlag != nil {
                    log.notice("controls available: \(available)")
                }
                lastControlsFlag = available
                sendStatus()
            }
        }
        updateHoldHeadphones() // expires remote holds (cheap; acts only on a change)
        let failed = sendFailures.exchange(0)
        if failed > 0 {
            let e = Int32(lastSendErrno.load())
            log.error("\(failed) audio sends failed in the last second: \(String(cString: strerror(e)), privacy: .public) (\(e))")
        }
        nudgeLogTicks += 1
        if nudgeLogTicks % 10 == 0 {
            lock.lock()
            for (key, s) in subscribers {
                // The phone's own view (from its keepalives): the only live playback health
                // signal when it's away on cellular and its log can't be pulled.
                log.notice("\(s.name, privacy: .public) @ \(key, privacy: .public): resent \(self.resentCounter.load()), buffer \(s.bufferMs) ms, loss \(String(format: "%.1f", Double(s.lossPermille) / 10), privacy: .public)%, nudges \(s.nudges) (max gap \(Int(s.maxNudgeGapMs)) ms)")
                s.nudges = 0; s.maxNudgeGapMs = 0
            }
            lock.unlock()
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
                var peak: Float = 0
                for i in 0..<(frame * ch) { peak = max(peak, abs(pcm[i])) }
                if peak > 0.001 { lastAudibleUptimeNs.store(DispatchTime.now().uptimeNanoseconds) }
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
        history.store(ptr, len, samplePos: samplePos)
        if samplePos % 4800 == 0, let hook = onPacketSent { hook(samplePos, DispatchTime.now().uptimeNanoseconds) }
        packetsCounter.add(1)
        bytesCounter.add(UInt32(len))
        if config.simulatedLoss > 0, Double.random(in: 0..<1) < config.simulatedLoss { return }
        var burstDelay = 0.0
        if config.simulatedBurstMs > 0 {
            let nowMs = Double(DispatchTime.now().uptimeNanoseconds) / 1e6
            let phase = nowMs.truncatingRemainder(dividingBy: config.simulatedBurstEveryMs)
            if phase < config.simulatedBurstMs { burstDelay = (config.simulatedBurstMs - phase) / 1000 }
        }
        if config.simulatedJitterMs > 0 || burstDelay > 0 {
            let copy = Data(bytes: ptr, count: len)
            let jitter = config.simulatedJitterMs > 0 ? Double.random(in: 0..<config.simulatedJitterMs) / 1000 : 0
            let delay = jitter + burstDelay
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
        for a in addrs where socket.send(ptr, len, to: a) < 0 {
            _ = lastSendErrno.exchange(UInt32(errno))
            sendFailures.add()
        }
    }
}
#endif

#if os(macOS)
/// Fixed ring of recent audio datagrams (preallocated, no allocation on the encode thread), so a
/// phone's RESEND can be answered with the original packet.
final class DatagramHistory {
    private let slots: Int
    private let capacity = Packet.audioOverhead + 1500
    private let storage: UnsafeMutablePointer<UInt8>
    private var lengths: [Int]
    private var positions: [UInt64]
    private var next = 0
    private let lock = NSLock()

    init(slots: Int) {
        self.slots = slots
        storage = .allocate(capacity: slots * capacity)
        lengths = [Int](repeating: 0, count: slots)
        positions = [UInt64](repeating: .max, count: slots)
    }

    deinit { storage.deallocate() }

    func store(_ ptr: UnsafePointer<UInt8>, _ len: Int, samplePos: UInt64) {
        guard len <= capacity else { return }
        lock.lock()
        (storage + next * capacity).update(from: ptr, count: len)
        lengths[next] = len
        positions[next] = samplePos
        next = (next + 1) % slots
        lock.unlock()
    }

    /// Calls `body` with the stored datagram for `samplePos`; false if it's no longer kept.
    @discardableResult
    func withDatagram(samplePos: UInt64, _ body: (UnsafeRawPointer, Int) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let i = positions.firstIndex(of: samplePos) else { return false }
        body(UnsafeRawPointer(storage + i * capacity), lengths[i])
        return true
    }
}
#endif
