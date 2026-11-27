import Foundation

/// The name of PulseAudio's (or pipewire-pulse's) default sink, via `pactl` (package
/// pulseaudio-utils, installed by default on Ubuntu desktops). The capture source polls it to
/// notice the output being switched, because a stream opened on `@DEFAULT_MONITOR@` keeps
/// recording the sink that was default when it opened.
enum DefaultSink {
    /// nil when pactl is missing or the server isn't reachable.
    static func current() -> String? {
        guard let exe = locate(),
              let r = CommandRunner.run(exe, ["get-default-sink"], timeout: 3), r.status == 0 else { return nil }
        return parse(r.stdout)
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
