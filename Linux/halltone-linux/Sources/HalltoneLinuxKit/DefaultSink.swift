import Foundation

/// The name of PulseAudio's (or pipewire-pulse's) default sink, via `pactl` (package
/// pulseaudio-utils, installed by default on Ubuntu desktops). The capture source polls it to
/// notice the output being switched, because a stream opened on `@DEFAULT_MONITOR@` keeps
/// recording the sink that was default when it opened.
enum DefaultSink {
    /// nil when pactl is missing or the server isn't reachable.
    static func current() -> String? {
        let p = Process()
        guard let exe = locate() else { return nil }
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["get-default-sink"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ output: String) -> String? {
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func locate() -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/usr/bin", "/usr/local/bin"]
        return dirs.map { $0 + "/pactl" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
