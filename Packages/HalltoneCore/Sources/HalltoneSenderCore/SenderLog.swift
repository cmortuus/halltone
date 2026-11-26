import Foundation
import HalltoneCore
#if canImport(os)
import os
#else

// On Linux there is no os.Logger. This stand-in accepts the same call shapes the sender uses
// (`log.notice("... \(x, privacy: .public)")`) and writes lines to stderr, which systemd's journal
// captures for the user service.

public enum LogPrivacy { case `public`, `private`, auto, sensitive }

public struct LogMessage: ExpressibleByStringInterpolation {
    let text: String
    public init(stringLiteral value: String) { text = value }
    public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }

    public struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        public init(literalCapacity: Int, interpolationCount: Int) { text.reserveCapacity(literalCapacity) }
        public mutating func appendLiteral(_ literal: String) { text += literal }
        public mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy = .auto) {
            text += String(describing: value)
        }
    }
}

public struct Logger {
    private let category: String
    public init(subsystem: String, category: String) { self.category = category }

    private static let lock = NSLock()
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func emit(_ level: String, _ message: LogMessage) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let line = "\(Self.clock.string(from: Date())) \(level) [\(category)] \(message.text)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    public func debug(_ message: LogMessage) { emit("D", message) }
    public func info(_ message: LogMessage) { emit("I", message) }
    public func notice(_ message: LogMessage) { emit("N", message) }
    public func warning(_ message: LogMessage) { emit("W", message) }
    public func error(_ message: LogMessage) { emit("E", message) }
    public func fault(_ message: LogMessage) { emit("F", message) }
}
#endif
