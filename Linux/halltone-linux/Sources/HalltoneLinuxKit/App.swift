import Foundation
import HalltoneCore
import HalltoneSenderCore

public enum App {
    public static let version = "0.1"

    /// Runs the executable's job up to (not including) waiting for a signal: parses flags, loads
    /// the config, starts the sender. Returns the running sender, or an exit code.
    public static func start(arguments: [String], hostname: String = ProcessInfo.processInfo.hostName)
        -> Result<LinuxRuntime, ExitCode> {
        let flags: Flags
        do { flags = try Flags.parse(arguments) } catch {
            printError("\(error)")
            return .failure(ExitCode(2))
        }
        if flags.help { print(Flags.usage); return .failure(ExitCode(0)) }
        if flags.version { print("halltone-linux \(version)"); return .failure(ExitCode(0)) }
        do {
            let prepared = try ConfigStore.prepare(flags: flags, hostname: hostname)
            let c = prepared.config
            let frame = c.codec == .opus ? "10 ms Opus" : "PCM \(c.frameMs == 2.5 ? "2.5" : "5") ms\(c.gameMode ? " (Game mode)" : "")"
            print("""
            halltone-linux \(version): \(c.name)
              pairing code: \(String(c.pairingCode))\(prepared.generatedCode ? "   (new: saved to \(prepared.path))" : "")
              streaming \(frame), udp/\(c.port), source \(c.source.rawValue)
            """)
            fflush(stdout)
            let runtime = try LinuxRuntime(config: c)
            try runtime.start()
            return .success(runtime)
        } catch {
            printError("\(error)")
            return .failure(ExitCode(1))
        }
    }

    private static func printError(_ text: String) {
        FileHandle.standardError.write(Data("halltone-linux: \(text)\n".utf8))
    }
}

public struct ExitCode: Error, Equatable {
    public let value: Int32
    public init(_ v: Int32) { value = v }
}
