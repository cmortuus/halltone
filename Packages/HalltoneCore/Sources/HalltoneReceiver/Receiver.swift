import Foundation
import Network
import os
import HalltoneCore

private let log = Logger(subsystem: Constants.logSubsystem, category: "Receiver")

/// UDP subscriber: SUBSCRIBE / KEEPALIVE / BYE, auto-reconnect, and feeding the decode pump.
public final class Receiver {
    public enum State: Equatable {
        case idle
        case connecting
        case subscribed(macName: String)
        case reconnecting
        case rejected(String)
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .idle, .rejected, .failed: return false
            default: return true
            }
        }
    }

    public struct Stats: Equatable {
        public var state: State = .idle
        public var macName = ""
        public var codec: CodecID?
        public var bufferMs = 0
        public var targetMs = 0
        public var lossPercent: Double = 0
        public var packetsPerSecond = 0
        public var kilobitsPerSecond = 0
        public var underruns: UInt64 = 0
        public var concealed: UInt64 = 0
        /// Rough playout delay inside the receiver: jitter buffer + hand-off ring.
        public var estimatedLatencyMs = 0
        /// Largest render callback seen, in frames.
        public var callbackFrames = 0
        /// Largest recent gap between packet arrivals (decaying), in ms.
        public var arrivalGapMs = 0
        /// The phone is on cellular (no Wi-Fi), using the larger cellular buffer.
        public var onCellular = false
        /// From the Mac's STATUS: whether headphone/lock-screen controls work. nil = unknown
        /// (older Mac app, or no STATUS yet).
        public var macControlsAvailable: Bool?
        /// From the Mac's STATUS: whether it can keep headphones on this phone. nil = unknown.
        public var macCanHoldHeadphones: Bool?
        /// From the Mac's STATUS: someone is using the Mac (drives Auto latency). nil = unknown.
        public var macUserActive: Bool?
        /// From the Mac's STATUS: keyboard/mouse input in the last ~20 s. nil = unknown.
        public var macInputRecent: Bool?
        /// The Mac understands explicit pause/play commands.
        public var macExplicitPlayPause = false
        /// Something is playing on the Mac (from its STATUS).
        public var macPlaying = true
        /// Bluetooth proximity to the Mac (see `phoneNearMac`). nil = unknown.
        public var phoneNearMac: Bool?
        /// What Auto latency acts on: near the Mac by Bluetooth if known, else the Mac's activity.
        public var atMac = false
        /// Diagnostics, max over the last 10 s: longest gap between audio packets as received
        /// (raw, not the decaying estimate), and longest gap between nudge timer firings. A timer
        /// gap as long as the packet gap means iOS wasn't running us, not that the network stalled.
        public var maxArrivalGapMs10s = 0
        public var maxTimerGapMs10s = 0
        /// Jitter buffer internals, for diagnostics: playing yet, how many resets, audio queued
        /// but not decoded, decoded but not yet played.
        public var jitterPrimed = false
        public var jitterResets: UInt64 = 0
        public var queuedMs = 0
        public var handoffMs = 0
        /// Decode thread's audio-workgroup join result (0 = joined; nil before the first join).
        public var workgroupStatus: Int?
        /// Retransmission: frames asked for again, and how many of those then arrived in time.
        public var resendRequested: UInt64 = 0
        public var resendRecovered: UInt64 = 0
        /// Glitch counters (cumulative): frames concealed, arrived too late, crossfade-trimmed
        /// (catch-up/drift), and stretched (drift).
        public var concealedFrames: UInt64 = 0
        public var lateFrames: UInt64 = 0
        public var trimmedFrames: UInt64 = 0
        public var stretchedFrames: UInt64 = 0
        public init() {}
    }

    public var onState: ((State) -> Void)?
    public var onStats: ((Stats) -> Void)?
    /// Test hook: (samplePos, uptime ns at which that frame reaches the sink), every 4800 samples.
    public var onFrameScheduled: ((UInt64, UInt64) -> Void)?
    /// Called (on the receiver queue) for every STATUS from the Mac.
    public var onMacStatus: ((StatusFlags) -> Void)?
    public private(set) var state: State = .idle {
        didSet { if state != oldValue { stats.state = state; onState?(state) } }
    }
    public private(set) var stats = Stats()

    /// Latency/robustness trade-off for the jitter buffer. Applies immediately (re-primes).
    /// While the phone is on cellular a larger cellular buffer is used regardless.
    public var latencyMode: LatencyMode = .auto {
        didSet { queue.async { [self] in applyEffectiveConfig() } }
    }

    /// Ask the Mac to keep headphones on this phone (stop it taking them back while listening).
    /// Sent on subscribe, on change, and repeated every few seconds since UDP can drop it.
    public var holdHeadphones = false {
        didSet { queue.async { [self] in sendHoldHeadphones() } }
    }

    /// Bluetooth proximity, from the app: true near the Mac, false away, nil unknown. When known
    /// it decides Auto latency; otherwise the Mac's "someone is using me" flag does.
    public var phoneNearMac: Bool? {
        didSet { queue.async { [self] in stats.phoneNearMac = phoneNearMac; updatePresence() } }
    }

    /// Notice holes in the stream and ask the Mac for them while there's still time to play them.
    private func trackForResend(session: UInt32, pos: UInt64) {
        let frame = frameSamplesForResend
        guard frame > 0 else { return }
        if session != newestSession { newestSession = session; newestPos = nil; missing.removeAll() }
        guard let newest = newestPos else { newestPos = pos; return }
        if pos <= newest {
            // Late, reordered or a retransmission.
            if missing.removeValue(forKey: pos) != nil { stats.resendRecovered += 1 }
            return
        }
        newestPos = pos
        let gapFrames = (pos - newest) / frame
        guard gapFrames > 1 else { return }
        // A hole of more than ~1 s is an outage or a stream jump, not loss worth chasing.
        guard gapFrames <= 100 else { return }
        let t = now()
        var ask: [UInt64] = []
        var p = newest + frame
        while p < pos, ask.count < Packet.maxResend {
            missing[p] = (t, 1); ask.append(p); p += frame
        }
        sendResend(ask)
    }

    private func sendResend(_ positions: [UInt64]) {
        guard !positions.isEmpty, case .subscribed = state, let c = connection else { return }
        stats.resendRequested += UInt64(positions.count)
        send(.resend(samplePositions: positions), over: c)
    }

    /// Ask once more for frames still missing after 150 ms; forget them after 2 s.
    private func retryResends() {
        guard !missing.isEmpty else { return }
        let t = now()
        var again: [UInt64] = []
        for (p, m) in missing {
            if t - m.asked > 2 { missing.removeValue(forKey: p); continue }
            if m.tries < 2, t - m.asked > 0.15, again.count < Packet.maxResend {
                missing[p] = (m.asked, m.tries + 1); again.append(p)
            }
        }
        sendResend(again.sorted())
    }

    private func updatePresence() {
        // Typing or mousing right now settles it; otherwise Bluetooth proximity if known, else
        // the Mac's minutes-long activity window.
        let atMac = stats.macInputRecent == true || (stats.phoneNearMac ?? (stats.macUserActive == true))
        guard atMac != stats.atMac else { return }
        stats.atMac = atMac
        if latencyMode == .auto, !onCellular, let pump {
            log.notice("\(atMac ? "at" : "away from", privacy: .public) the Mac; retuning")
            pump.retune(effectiveConfig(frameSamples: pump.jitter.frameSamples))
        }
        publish()
    }

    private func sendHoldHeadphones() {
        guard case .subscribed = state, let c = connection else { return }
        send(.control(command: holdHeadphones ? .holdHeadphonesOn : .holdHeadphonesOff), over: c)
        send(.control(command: listening ? .listening : .notListening), over: c)
    }

    /// False while the app is paused (headphones out): the Mac stops capturing and sending,
    /// and no audio is expected, but the subscription stays up for an instant resume.
    public var listening = true {
        didSet {
            queue.async { [self] in
                // The Mac needs a moment to restart capture: don't call it lost too soon.
                if listening { lastAudioAt = now() + 3 }
                sendHoldHeadphones()
            }
        }
    }

    /// True while the phone has no Wi-Fi or wired path (reaching the Mac over cellular/VPN).
    private var onCellular = false

    private func effectiveConfig(frameSamples: Int) -> JitterBuffer.Config {
        if onCellular { return .cellular(frameSamples: frameSamples) }
        if latencyMode == .auto {
            return .preset(stats.atMac ? .lowest : .stable, frameSamples: frameSamples)
        }
        return .preset(latencyMode, frameSamples: frameSamples)
    }

    /// Mode change (or cellular ↔ Wi-Fi): resize smoothly, keeping what's been learned about
    /// the network's gaps. Flushing restarted at the new mode's default (Stable at 300 ms while
    /// the Wi-Fi had 700 ms holes) and played a gap.
    private func applyEffectiveConfig() {
        guard let pump else { return }
        pump.retune(effectiveConfig(frameSamples: pump.jitter.frameSamples))
    }

    private let sink: PlaybackSink
    /// High priority: packet arrival times feed the jitter buffer's gap estimate, so a queue that
    /// iOS batches in the background would look like a bursty network and inflate latency.
    private let queue = DispatchQueue(label: "com.halltone.receiver", qos: .userInteractive)
    private var connection: NWConnection?
    private var endpoint: NWEndpoint?
    private var pairingCode: UInt32 = 0
    private var deviceName = "iPhone"
    private var seq: UInt32 = 0
    private var pump: DecodePump?
    private var timer: DispatchSourceTimer?
    private var nudgeTimer: DispatchSourceTimer?
    private lazy var nudgePacket = Packet(seq: 0, session: 0, message: .nudge).encode()
    private var pathMonitor: NWPathMonitor?
    private var lastAudioAt: TimeInterval = 0
    private var lastSubscribeAt: TimeInterval = 0
    private var reconnectingSince: TimeInterval = 0
    private var lastAudioSeq: UInt32 = 0
    private var packetsThisSecond = 0
    private var bytesThisSecond = 0
    private var lastLost: UInt64 = 0
    private var lastReceived: UInt64 = 0
    private var pathInterfaces: Set<String> = []
    private var sessionKnown: UInt32?
    private var lastTimerFire: TimeInterval?
    private var windowTimerGap: TimeInterval = 0
    private var lastPacketArrival: TimeInterval?
    /// Retransmission bookkeeping: newest samplePos seen, frames asked for again (pos → when
    /// first asked, tries), and the stream's frame size.
    private var newestPos: UInt64?
    private var newestSession: UInt32?
    private var missing: [UInt64: (asked: TimeInterval, tries: Int)] = [:]
    private var frameSamplesForResend: UInt64 = 0
    private var windowArrivalGap: TimeInterval = 0

    public init(sink: PlaybackSink) {
        self.sink = sink
    }

    // MARK: - Public API

    public func connect(to endpoint: NWEndpoint, pairingCode: UInt32, deviceName: String) {
        queue.async { [self] in
            self.endpoint = endpoint
            self.pairingCode = pairingCode
            self.deviceName = deviceName
            tearDownConnection()
            state = .connecting
            do { try sink.start() } catch {
                state = .failed("audio engine: \(error)")
                return
            }
            openConnection()
            startTimers()
        }
    }

    public func disconnect() {
        queue.async { [self] in
            if let c = connection { send(.bye, over: c) }
            tearDownConnection()
            timer?.cancel(); timer = nil
            nudgeTimer?.cancel(); nudgeTimer = nil
            pathMonitor?.cancel(); pathMonitor = nil
            pump?.stop(); pump = nil
            sink.stop()
            state = .idle
            publish()
        }
    }

    public func sendControl(_ cmd: ControlCommand) {
        queue.async { [self] in
            if let c = connection { send(.control(command: cmd), over: c) }
        }
    }

    /// Re-create the socket (e.g. after a Wi-Fi interface change). Keeps the subscription logic going.
    public func reconnectNow() {
        queue.async { [self] in
            guard state.isActive else { return }
            log.info("recreating connection")
            tearDownConnection()
            openConnection()
        }
    }

    // MARK: - Connection

    private func openConnection() {
        guard let endpoint else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        // Marks traffic as voice (WMM AC_VO): prioritized, and less power-save batching.
        params.serviceClass = .interactiveVoice
        let c = NWConnection(to: endpoint, using: params)
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                log.info("socket ready → \(String(describing: endpoint), privacy: .public)")
                self.subscribe()
            case .waiting(let err):
                log.notice("socket waiting: \(err)")
            case .failed(let err):
                log.error("socket failed: \(err)")
                if self.state.isActive { self.state = .reconnecting; self.reconnectingSince = self.now() }
            default: break
            }
        }
        connection = c
        c.start(queue: queue)
        receiveLoop(c)
    }

    private func tearDownConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func receiveLoop(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.connection === c else { return }
            if let data, let packet = Packet.decode(data) { self.handle(packet, bytes: data.count) }
            if error == nil { self.receiveLoop(c) }
        }
    }

    private func subscribe() {
        guard let c = connection else { return }
        lastSubscribeAt = now()
        send(.subscribe(pairingCode: pairingCode, deviceName: deviceName), over: c)
    }

    private func send(_ message: Message, over c: NWConnection) {
        seq &+= 1
        let data = Packet(seq: seq, session: 0, message: message).encode()
        c.send(content: data, completion: .contentProcessed { _ in })
    }

    private func handle(_ packet: Packet, bytes: Int) {
        switch packet.message {
        case .subscribeAck(let codec, let rate, let channels, let frameSamples, let macName):
            guard rate == UInt32(Constants.sampleRate), channels == 2 else {
                state = .failed("unsupported stream format \(rate) Hz / \(channels) ch")
                return
            }
            if pump == nil || stats.codec != codec || pump?.jitter.frameSamples != Int(frameSamples) {
                pump?.stop()
                guard let decoder = CodecFactory.makeDecoder(for: codec, frameSamples: Int(frameSamples)) else {
                    state = .failed("codec \(codec) not supported on this build")
                    return
                }
                let jb = JitterBuffer(config: effectiveConfig(frameSamples: Int(frameSamples)))
                let p = DecodePump(jitter: jb, decoder: decoder, sink: sink)
                p.onFrameScheduled = onFrameScheduled
                p.start()
                pump = p
                stats.codec = codec
            }
            stats.macName = macName
            if case .subscribed = state {} else { log.info("subscribed to \(macName, privacy: .public) (\(String(describing: codec), privacy: .public), \(frameSamples) spf)") }
            state = .subscribed(macName: macName)
            frameSamplesForResend = UInt64(frameSamples)
            sendHoldHeadphones()
            lastAudioAt = now()
        case .subscribeNak(let reason):
            let text = reason == NakReason.badPairingCode.rawValue ? "wrong pairing code" : "rejected (\(reason))"
            log.error("subscribe rejected: \(text, privacy: .public)")
            state = .rejected(text)
            tearDownConnection()
        case .audio(let samplePos, _, let payload):
            lastAudioAt = now()
            if let last = lastPacketArrival { windowArrivalGap = max(windowArrivalGap, lastAudioAt - last) }
            lastPacketArrival = lastAudioAt
            lastAudioSeq = packet.header.seq
            packetsThisSecond += 1
            bytesThisSecond += bytes
            if case .reconnecting = state { state = .subscribed(macName: stats.macName) }
            trackForResend(session: packet.header.session, pos: samplePos)
            pump?.push(session: packet.header.session, samplePos: samplePos, payload: payload)
        case .status(let flags):
            let available = flags.contains(.controlsAvailable)
            let canHold = flags.contains(.canHoldHeadphones)
            let userActive = flags.contains(.userAtMac)
            let inputRecent = flags.contains(.userInputRecent)
            stats.macExplicitPlayPause = flags.contains(.explicitPlayPause)
            if stats.macExplicitPlayPause, stats.macPlaying != flags.contains(.macPlaying) {
                stats.macPlaying = flags.contains(.macPlaying)
                publish()
            }
            if stats.macControlsAvailable != available || stats.macCanHoldHeadphones != canHold
                || stats.macUserActive != userActive || stats.macInputRecent != inputRecent {
                stats.macInputRecent = inputRecent
                stats.macControlsAvailable = available
                stats.macCanHoldHeadphones = canHold
                stats.macUserActive = userActive
                updatePresence()
                publish()
            }
            onMacStatus?(flags)
        case .bye:
            log.notice("sender said bye")
            if state.isActive { state = .reconnecting; reconnectingSince = now() }
        default:
            break
        }
    }

    // MARK: - Timers

    private func startTimers() {
        nudgeTimer?.cancel()
        let n = DispatchSource.makeTimerSource(queue: queue)
        n.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(5))
        n.setEventHandler { [weak self] in
            // Keeps a dozing Wi-Fi radio awake; pointless (and costs data) on cellular.
            guard let self else { return }
            let t = self.now()
            if let last = self.lastTimerFire { self.windowTimerGap = max(self.windowTimerGap, t - last) }
            self.lastTimerFire = t
            guard !self.onCellular, case .subscribed = self.state, let c = self.connection else { return }
            c.send(content: self.nudgePacket, completion: .idempotent)
        }
        n.resume()
        nudgeTimer = n

        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        if pathMonitor == nil {
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let types = path.availableInterfaces.map(\.type)
                let cellular = !types.contains(.wifi) && !types.contains(.wiredEthernet) && types.contains(.cellular)
                if cellular != self.onCellular {
                    self.onCellular = cellular
                    self.stats.onCellular = cellular
                    log.notice("now on \(cellular ? "cellular" : "Wi-Fi", privacy: .public)")
                    self.applyEffectiveConfig()
                    self.publish()
                }
                let names = Set(path.availableInterfaces.map { $0.name })
                if self.pathInterfaces != names, !self.pathInterfaces.isEmpty, self.state.isActive {
                    log.info("network path changed: \(names.sorted().joined(separator: ","), privacy: .public)")
                    self.tearDownConnection()
                    self.openConnection()
                }
                self.pathInterfaces = names
            }
            m.start(queue: queue)
            pathMonitor = m
        }
    }

    private var tickCount = 0
    private func tick() {
        let t = now()
        tickCount += 1
        switch state {
        case .subscribed:
            if listening, t - lastAudioAt > Constants.audioSilenceTimeout {
                log.notice("no audio for \(Constants.audioSilenceTimeout)s; reconnecting")
                state = .reconnecting
                reconnectingSince = t
            }
        case .reconnecting, .connecting:
            if t - lastSubscribeAt >= 1 {
                if connection == nil || t - reconnectingSince > 10 {
                    reconnectingSince = t
                    tearDownConnection()
                    openConnection() // subscribe() fires on .ready
                } else {
                    subscribe()
                }
            }
        default:
            break
        }
        retryResends()
        if tickCount % 4 == 0 { everySecond() }
    }

    private func everySecond() {
        let js = pump?.stats ?? JitterBuffer.Stats()
        let (lost, recv) = Self.counterDeltas(lost: js.lost, received: js.received,
                                              lastLost: lastLost, lastReceived: lastReceived)
        lastLost = js.lost; lastReceived = js.received
        let total = lost + recv
        let permille = total > 0 ? Int(lost * 1000 / total) : 0
        stats.lossPercent = Double(permille) / 10
        stats.bufferMs = Int(js.depthMs)
        stats.targetMs = Int(js.targetMs)
        stats.underruns = js.underruns
        stats.concealed = js.lost
        stats.packetsPerSecond = packetsThisSecond
        stats.kilobitsPerSecond = bytesThisSecond * 8 / 1000
        packetsThisSecond = 0; bytesThisSecond = 0
        stats.estimatedLatencyMs = Int(js.depthMs)
        stats.callbackFrames = Int(sink.maxCallbackFrames.load())
        stats.arrivalGapMs = Int(pump?.recentGapMs ?? 0)
        stats.jitterPrimed = js.primed
        if let p = pump { let w = Int(Int64(bitPattern: p.workgroupStatus.load())); stats.workgroupStatus = w == -99 ? nil : w }
        stats.concealedFrames = js.lost
        stats.lateFrames = js.late
        stats.trimmedFrames = js.driftDrops
        stats.stretchedFrames = js.driftDups
        stats.jitterResets = js.resets
        stats.queuedMs = Int(Double(pump?.queuedSamples ?? 0) * 1000 / Constants.sampleRate)
        stats.handoffMs = Int(Double(sink.ring.availableToRead / Constants.channels) * 1000 / Constants.sampleRate)
        if tickCount % 40 == 0 {
            stats.maxArrivalGapMs10s = Int(windowArrivalGap * 1000)
            stats.maxTimerGapMs10s = Int(windowTimerGap * 1000)
            windowArrivalGap = 0; windowTimerGap = 0
        }
        if case .subscribed = state, let c = connection {
            send(.keepalive(lastSeqReceived: lastAudioSeq, lossPermille: UInt16(clamping: permille),
                            bufferMs: UInt16(clamping: stats.bufferMs)), over: c)
            if tickCount % 20 == 0 { sendHoldHeadphones() }
        }
        publish()
    }

    /// Per-second packet counts from the jitter buffer's running totals. A reconnect (or a
    /// disconnect, which leaves no pump) restarts those totals at zero; wrapping the subtraction
    /// then made the sum overflow and crash the app.
    static func counterDeltas(lost: UInt64, received: UInt64, lastLost: UInt64,
                              lastReceived: UInt64) -> (lost: UInt64, received: UInt64) {
        guard lost >= lastLost, received >= lastReceived else { return (lost, received) }
        return (lost - lastLost, received - lastReceived)
    }

    private func publish() { onStats?(stats) }
    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
