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
        /// From the Mac's STATUS: whether headphone/lock-screen controls work. nil = unknown
        /// (older Mac app, or no STATUS yet).
        public var macControlsAvailable: Bool?
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

    private let sink: PlaybackSink
    private let queue = DispatchQueue(label: "com.halltone.receiver")
    private var connection: NWConnection?
    private var endpoint: NWEndpoint?
    private var pairingCode: UInt32 = 0
    private var deviceName = "iPhone"
    private var seq: UInt32 = 0
    private var pump: DecodePump?
    private var timer: DispatchSourceTimer?
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
                let jb = JitterBuffer(config: JitterBuffer.Config(frameSamples: Int(frameSamples)))
                let p = DecodePump(jitter: jb, decoder: decoder, sink: sink)
                p.onFrameScheduled = onFrameScheduled
                p.start()
                pump = p
                stats.codec = codec
            }
            stats.macName = macName
            if case .subscribed = state {} else { log.info("subscribed to \(macName, privacy: .public) (\(String(describing: codec), privacy: .public), \(frameSamples) spf)") }
            state = .subscribed(macName: macName)
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
            if stats.macControlsAvailable != available { stats.macControlsAvailable = available; publish() }
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
        if case .subscribed = state, let c = connection {
            send(.keepalive(lastSeqReceived: lastAudioSeq, lossPermille: UInt16(clamping: permille),
                            bufferMs: UInt16(clamping: stats.bufferMs)), over: c)
        }
        publish()
    }

    private func publish() { onStats?(stats) }
    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
