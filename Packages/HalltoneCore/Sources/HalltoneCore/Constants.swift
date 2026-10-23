import Foundation

public enum Constants {
    public static let logSubsystem = "com.halltone"
    public static let serviceType = "_halltone._udp"
    public static let defaultPort: UInt16 = 47800
    /// TCP: phones upload their diagnostics log here once it reaches 25 MB.
    public static let logUploadPort: UInt16 = 47801
    public static let protocolVersion: UInt8 = 1
    public static let magic: UInt16 = 0x4854 // "HT"

    public static let sampleRate: Double = 48_000
    public static let channels = 2
    /// Hard cap on a datagram so it stays well under the path MTU.
    public static let maxDatagramBytes = 1200

    /// PCM16 frame: 240 samples (5 ms) * 2 ch * 2 B = 960 B payload.
    public static let pcmFrameSamples = 240
    /// Opus frame: 480 samples (10 ms).
    public static let opusFrameSamples = 480

    public static let keepaliveInterval: TimeInterval = 1.0
    /// A phone silent this long is dropped. Long enough to ride out a Wi-Fi hole or a switch
    /// between Wi-Fi and a VPN without tearing down capture (5 s did, repeatedly).
    public static let subscriberTimeout: TimeInterval = 20.0
    public static let audioSilenceTimeout: TimeInterval = 1.5

    /// Bluetooth LE beacon the Mac app advertises so the phone can tell from signal strength
    /// whether it's near the Mac (Auto latency). One readable characteristic: the Mac's name.
    public static let proximityServiceUUID = "3E408C1B-0C89-4E46-BA16-0D8C3334D5C8"
    public static let proximityNameUUID = "E9CE01AB-CF4A-4622-B047-CDC7D290435E"
}
