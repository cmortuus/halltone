import Foundation

// Wire protocol v1. All integers big-endian. One datagram = one message.
//
// Header (12 bytes): magic u16 (0x4541), version u8 (1), type u8, seq u32, session u32.

public enum MessageType: UInt8 {
    case subscribe = 0x01
    case keepalive = 0x02
    case bye = 0x03
    case subscribeAck = 0x04
    case subscribeNak = 0x05
    /// Mac → phone. Sent after SUBSCRIBE_ACK, whenever a flag changes, every few seconds, and
    /// right after a CONTROL that could not be carried out. Older receivers ignore it.
    case status = 0x06
    /// Phone → Mac, empty, every ~20 ms while playing. Frequent uplink traffic keeps the phone's
    /// Wi-Fi radio out of power save, so audio arrives steadily instead of in bursts. Ignored.
    case nudge = 0x07
    /// Phone → Mac: resend these audio frames (by samplePos). A deep buffer has hundreds of ms
    /// to recover packets Wi-Fi dropped (bursty loss while the phone dozes), which FEC can't
    /// cover. The Mac answers with the original AUDIO datagrams. Older Macs ignore it.
    case resend = 0x08
    case audio = 0x10
    case control = 0x20
}

public enum CodecID: UInt8 {
    case pcm16 = 1
    case opus = 2
}

public enum ControlCommand: UInt8 {
    case playPause = 1
    case next = 2
    case previous = 3
    /// "Keep headphones on this iPhone" on/off. The phone repeats its current choice every few
    /// seconds (UDP); a Mac that doesn't know these drops them.
    case holdHeadphonesOn = 4
    case holdHeadphonesOff = 5
    /// Explicit pause / play: the Mac presses its play/pause key only if that changes anything
    /// (it knows whether something is playing from the captured audio). A plain toggle restarted
    /// a video the user had already paused when taking AirPods out (iOS sends "pause" then).
    /// Sent only to Macs that advertise `explicitPlayPause`.
    case pause = 6
    case play = 7
    /// The phone is (not) playing: paused while its headphones are out. While no phone is
    /// listening the Mac stops capturing, which also unmutes its speakers, but keeps the
    /// subscription so playback resumes instantly. Repeated every few seconds (UDP).
    case listening = 8
    case notListening = 9

    /// The media-key commands (as opposed to settings like holdHeadphones* and listening).
    public var isMediaKey: Bool {
        switch self {
        case .playPause, .next, .previous, .pause, .play: return true
        case .holdHeadphonesOn, .holdHeadphonesOff, .listening, .notListening: return false
        }
    }
}

/// Bits of the STATUS message's `flags` byte.
public struct StatusFlags: OptionSet, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// The Mac can carry out CONTROL commands (play/pause/next/previous).
    public static let controlsAvailable = StatusFlags(rawValue: 1 << 0)
    /// The most recent CONTROL could not be carried out (permission missing).
    public static let lastControlFailed = StatusFlags(rawValue: 1 << 1)
    /// The Mac supports keeping headphones on the phone (holdHeadphones* commands).
    public static let canHoldHeadphones = StatusFlags(rawValue: 1 << 2)
    /// Someone is using the Mac right now (recent keyboard/mouse input, screen unlocked). The
    /// phone's Auto latency mode tracks it: close to real time at the Mac, a big buffer away.
    public static let userAtMac = StatusFlags(rawValue: 1 << 3)
    /// Keyboard/mouse input on the Mac in the last ~20 s: someone is definitely there. Breaks
    /// ties for the phone's Bluetooth proximity (a phone in a pocket at the desk reads like the
    /// next room) and tells it what "at the desk" looks like.
    public static let userInputRecent = StatusFlags(rawValue: 1 << 4)
    /// The Mac understands CONTROL pause/play (not just the toggle).
    public static let explicitPlayPause = StatusFlags(rawValue: 1 << 5)
    /// Something on the Mac is playing (audible in the last ~2 s). The phone mirrors it on the
    /// lock screen, which is what iOS uses to choose play vs pause for a headphone press.
    public static let macPlaying = StatusFlags(rawValue: 1 << 6)
}

public enum NakReason: UInt8 {
    case badPairingCode = 1
}

public struct Header: Equatable {
    public static let size = 12
    public var type: MessageType
    public var seq: UInt32
    public var session: UInt32

    public init(type: MessageType, seq: UInt32, session: UInt32) {
        self.type = type; self.seq = seq; self.session = session
    }
}

public enum Message: Equatable {
    case subscribe(pairingCode: UInt32, deviceName: String)
    case keepalive(lastSeqReceived: UInt32, lossPermille: UInt16, bufferMs: UInt16)
    case bye
    case subscribeAck(codec: CodecID, sampleRate: UInt32, channels: UInt8, frameSamples: UInt16, macName: String)
    case subscribeNak(reason: UInt8)
    case status(flags: StatusFlags)
    case nudge
    case resend(samplePositions: [UInt64])
    case audio(samplePos: UInt64, codec: CodecID, payload: Data)
    case control(command: ControlCommand)

    public var type: MessageType {
        switch self {
        case .subscribe: return .subscribe
        case .keepalive: return .keepalive
        case .bye: return .bye
        case .subscribeAck: return .subscribeAck
        case .subscribeNak: return .subscribeNak
        case .status: return .status
        case .nudge: return .nudge
        case .resend: return .resend
        case .audio: return .audio
        case .control: return .control
        }
    }
}

public struct Packet: Equatable {
    public var header: Header
    public var message: Message

    public init(header: Header, message: Message) {
        self.header = header; self.message = message
    }

    public init(seq: UInt32, session: UInt32, message: Message) {
        self.header = Header(type: message.type, seq: seq, session: session)
        self.message = message
    }

    /// Most frames one RESEND may ask for.
    public static let maxResend = 64

    /// Maximum serialized size of the audio header (common header + samplePos + codec + len).
    public static let audioOverhead = Header.size + 8 + 1 + 2

    public func encode() -> Data {
        var w = ByteWriter(capacity: 64)
        w.u16(Constants.magic)
        w.u8(Constants.protocolVersion)
        w.u8(header.type.rawValue)
        w.u32(header.seq)
        w.u32(header.session)
        switch message {
        case .subscribe(let code, let name):
            w.u32(code)
            w.shortString(name)
        case .keepalive(let last, let loss, let buf):
            w.u32(last); w.u16(loss); w.u16(buf)
        case .bye:
            break
        case .subscribeAck(let codec, let rate, let ch, let frame, let name):
            w.u8(codec.rawValue); w.u32(rate); w.u8(ch); w.u16(frame); w.shortString(name)
        case .subscribeNak(let reason):
            w.u8(reason)
        case .status(let flags):
            w.u8(flags.rawValue)
        case .nudge:
            break
        case .resend(let positions):
            let n = min(positions.count, Packet.maxResend)
            w.u8(UInt8(n))
            for p in positions.prefix(n) { w.u64(p) }
        case .audio(let pos, let codec, let payload):
            w.u64(pos); w.u8(codec.rawValue); w.u16(UInt16(min(payload.count, Int(UInt16.max)))); w.bytes(payload)
        case .control(let cmd):
            w.u8(cmd.rawValue)
        }
        return w.data
    }

    /// Returns nil for anything malformed. Never traps on bad input.
    public static func decode(_ data: Data) -> Packet? {
        var r = ByteReader(data)
        guard let magic = r.u16(), magic == Constants.magic,
              let version = r.u8(), version == Constants.protocolVersion,
              let rawType = r.u8(), let type = MessageType(rawValue: rawType),
              let seq = r.u32(), let session = r.u32() else { return nil }
        let header = Header(type: type, seq: seq, session: session)
        let message: Message
        switch type {
        case .subscribe:
            guard let code = r.u32(), let name = r.shortString() else { return nil }
            message = .subscribe(pairingCode: code, deviceName: name)
        case .keepalive:
            guard let last = r.u32(), let loss = r.u16(), let buf = r.u16() else { return nil }
            message = .keepalive(lastSeqReceived: last, lossPermille: loss, bufferMs: buf)
        case .bye:
            message = .bye
        case .subscribeAck:
            guard let rawCodec = r.u8(), let codec = CodecID(rawValue: rawCodec), let rate = r.u32(),
                  let ch = r.u8(), let frame = r.u16(), let name = r.shortString() else { return nil }
            message = .subscribeAck(codec: codec, sampleRate: rate, channels: ch, frameSamples: frame, macName: name)
        case .subscribeNak:
            guard let reason = r.u8() else { return nil }
            message = .subscribeNak(reason: reason)
        case .status:
            guard let flags = r.u8() else { return nil }
            message = .status(flags: StatusFlags(rawValue: flags))
        case .nudge:
            message = .nudge
        case .resend:
            guard let n = r.u8(), n <= Packet.maxResend else { return nil }
            var positions: [UInt64] = []
            for _ in 0..<n {
                guard let p = r.u64() else { return nil }
                positions.append(p)
            }
            message = .resend(samplePositions: positions)
        case .audio:
            guard let pos = r.u64(), let rawCodec = r.u8(), let codec = CodecID(rawValue: rawCodec),
                  let len = r.u16(), let payload = r.bytes(Int(len)) else { return nil }
            message = .audio(samplePos: pos, codec: codec, payload: payload)
        case .control:
            guard let raw = r.u8(), let cmd = ControlCommand(rawValue: raw) else { return nil }
            message = .control(command: cmd)
        }
        return Packet(header: header, message: message)
    }
}

// MARK: - Byte helpers

struct ByteWriter {
    var data: Data
    init(capacity: Int) { data = Data(capacity: capacity) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
    mutating func bytes(_ d: Data) { data.append(d) }
    /// u8 length + UTF-8 (truncated to 255 bytes on a character boundary).
    mutating func shortString(_ s: String) {
        var utf8 = Data(s.utf8)
        if utf8.count > 255 {
            var cut = String(decoding: utf8.prefix(255), as: UTF8.self)
            while cut.utf8.count > 255 { cut.removeLast() }
            utf8 = Data(cut.utf8)
        }
        u8(UInt8(utf8.count))
        data.append(utf8)
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int
    private let end: Int

    init(_ data: Data) { self.data = data; offset = data.startIndex; end = data.endIndex }

    var remaining: Int { end - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return data[offset]
    }
    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }
    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(data[offset + i]) }
        offset += 4
        return v
    }
    mutating func u64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(data[offset + i]) }
        offset += 8
        return v
    }
    mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, remaining >= n else { return nil }
        defer { offset += n }
        return Data(data[offset..<(offset + n)])
    }
    mutating func shortString() -> String? {
        guard let len = u8(), let d = bytes(Int(len)) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Allocation-free AUDIO fast path

extension Packet {
    /// Writes the common header + AUDIO fields into `buf` (capacity >= audioOverhead). The caller
    /// encodes the payload directly after `audioOverhead` bytes and sends `audioOverhead + len`.
    @inline(__always)
    public static func writeAudioHeader(into buf: UnsafeMutablePointer<UInt8>, seq: UInt32, session: UInt32,
                                        samplePos: UInt64, codec: CodecID, payloadLength: Int) {
        buf[0] = UInt8(Constants.magic >> 8); buf[1] = UInt8(Constants.magic & 0xff)
        buf[2] = Constants.protocolVersion
        buf[3] = MessageType.audio.rawValue
        var o = 4
        for shift in stride(from: 24, through: 0, by: -8) { buf[o] = UInt8((seq >> UInt32(shift)) & 0xff); o += 1 }
        for shift in stride(from: 24, through: 0, by: -8) { buf[o] = UInt8((session >> UInt32(shift)) & 0xff); o += 1 }
        for shift in stride(from: 56, through: 0, by: -8) { buf[o] = UInt8((samplePos >> UInt64(shift)) & 0xff); o += 1 }
        buf[o] = codec.rawValue; o += 1
        buf[o] = UInt8((payloadLength >> 8) & 0xff); buf[o + 1] = UInt8(payloadLength & 0xff)
    }
}
