import Foundation

public enum Constants {
    public static let logSubsystem = "com.halltone"
    public static let serviceType = "_halltone._udp"
    public static let defaultPort: UInt16 = 47800
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
    public static let subscriberTimeout: TimeInterval = 5.0
    public static let audioSilenceTimeout: TimeInterval = 1.5
}
