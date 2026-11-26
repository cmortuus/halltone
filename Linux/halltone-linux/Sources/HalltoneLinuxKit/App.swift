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
              streaming \(frame), udp/\(c.port), source \(c.source.name)
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

    /// `halltone-linux dialog on|off|status [--socket <path>]`; returns the exit code.
    public static func dialogCommand(_ args: [String]) -> Int32 {
        var word: String?
        var socket = ControlSocket.defaultPath()
        var i = 0
        while i < args.count {
            if args[i] == "--socket", i + 1 < args.count { socket = args[i + 1]; i += 2; continue }
            if args[i].hasPrefix("--socket=") { socket = String(args[i].dropFirst(9)); i += 1; continue }
            if word == nil { word = args[i] } else { word = "?" }
            i += 1
        }
        guard let word, ["on", "off", "status", "toggle"].contains(word) else {
            printError("usage: halltone-linux dialog on|off|status [--socket <path>]")
            return 2
        }
        let r = ControlSocket.request(path: socket, line: word)
        guard let reply = r.reply else {
            printError(r.error ?? "no answer")
            return 1
        }
        print(reply.trimmingCharacters(in: .newlines))
        return reply.hasPrefix("error") ? 1 : 0
    }

    private static func printError(_ text: String) {
        FileHandle.standardError.write(Data("halltone-linux: \(text)\n".utf8))
    }
}

public struct ExitCode: Error, Equatable {
    public let value: Int32
    public init(_ v: Int32) { value = v }
}
