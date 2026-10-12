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
    public var latencyMode: LatencyMode = .balanced {
        didSet { queue.async { [self] in applyEffectiveConfig() } }
    }

    /// Ask the Mac to keep headphones on this phone (stop it taking them back while listening).
    /// Sent on subscribe, on change, and repeated every few seconds since UDP can drop it.
    public var holdHeadphones = false {
        didSet { queue.async { [self] in sendHoldHeadphones() } }
    }

    private func sendHoldHeadphones() {
        guard case .subscribed = state, let c = connection else { return }
        send(.control(command: holdHeadphones ? .holdHeadphonesOn : .holdHeadphonesOff), over: c)
    }

    /// True while the phone has no Wi-Fi or wired path (reaching the Mac over cellular/VPN).
    private var onCellular = false

    private func effectiveConfig(frameSamples: Int) -> JitterBuffer.Config {
        onCellular ? .cellular(frameSamples: frameSamples) : .preset(latencyMode, frameSamples: frameSamples)
    }

    private func applyEffectiveConfig() {
        guard let pump else { return }
        pump.apply(effectiveConfig(frameSamples: pump.jitter.frameSamples))
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
            sendHoldHeadphones()
            lastAudioAt = now()
        case .subscribeNak(let reason):
            let text = reason == NakReason.badPairingCode.rawValue ? "wrong pairing code" : "rejected (\(reason))"
            log.error("subscribe rejected: \(text, privacy: .public)")
            state = .rejected(text)
            tearDownConnection()
        case .audio(let samplePos, _, let payload):
            lastAudioAt = now()
            lastAudioSeq = packet.header.seq
            packetsThisSecond += 1
            bytesThisSecond += bytes
            if case .reconnecting = state { state = .subscribed(macName: stats.macName) }
            pump?.push(session: packet.header.session, samplePos: samplePos, payload: payload)
        case .status(let flags):
            let available = flags.contains(.controlsAvailable)
            let canHold = flags.contains(.canHoldHeadphones)
            if stats.macControlsAvailable != available || stats.macCanHoldHeadphones != canHold {
                stats.macControlsAvailable = available
                stats.macCanHoldHeadphones = canHold
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
            guard let self, !self.onCellular, case .subscribed = self.state, let c = self.connection else { return }
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
            if t - lastAudioAt > Constants.audioSilenceTimeout {
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
        if tickCount % 4 == 0 { everySecond() }
    }

    private func everySecond() {
        let js = pump?.stats ?? JitterBuffer.Stats()
        let lost = js.lost &- lastLost
        let recv = js.received &- lastReceived
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
        if case .subscribed = state, let c = connection {
            send(.keepalive(lastSeqReceived: lastAudioSeq, lossPermille: UInt16(clamping: permille),
                            bufferMs: UInt16(clamping: stats.bufferMs)), over: c)
            if tickCount % 20 == 0 { sendHoldHeadphones() }
        }
        publish()
    }

    private func publish() { onStats?(stats) }
    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
