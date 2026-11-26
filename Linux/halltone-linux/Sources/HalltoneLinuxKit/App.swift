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

    /// The MediaController for `players` / `media`: pin and ignore from the config file and flags
    /// (no pairing code needed).
    private static func standaloneMedia(_ args: [String]) throws -> MediaController {
        var flags = try Flags.parse(args)
        flags.pairingCode = flags.pairingCode ?? "1000"
        let file = try ConfigStore.load(path: flags.configPath ?? ConfigStore.defaultPath())
        let settings = try MediaSettings.resolve(file: file["media"], flags: flags)
        return MediaController(pin: settings.player, ignore: settings.ignore)
    }

    /// `halltone-linux players`: every MPRIS player, its status, and which one commands would reach.
    public static func playersCommand(_ args: [String]) -> Int32 {
        do {
            let media = try standaloneMedia(args)
            guard let entries = media.listing() else {
                printError("can't reach the D-Bus session bus (is busctl installed and a desktop session running?)")
                return 1
            }
            if entries.isEmpty { print("no MPRIS players (open a player that supports media keys, e.g. Firefox with a video)"); return 0 }
            for e in entries {
                let p = e.player
                let note = e.ignored ? "  (ignored)" : e.chosen ? "  <- controlled" : ""
                let title = p.title.isEmpty ? "" : "  \(p.title)"
                print("\(p.status.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(p.shortName)\(p.identity.isEmpty ? "" : " [\(p.identity)]")\(title)\(note)")
            }
            return 0
        } catch { printError("\(error)"); return 2 }
    }

    /// `halltone-linux apps`: the audio apps playing now (PulseAudio sink inputs), so the user can
    /// find the game's name for `dialogPause.sourceApp`; streams of the MPRIS player are marked.
    public static func appsCommand(_ args: [String]) -> Int32 {
        do {
            let media = try standaloneMedia(args)
            guard let pactl = MacLocator.find("pactl") else { printError("pactl not found (package pulseaudio-utils)"); return 1 }
            guard let json = AppStreamCapture.listSinkInputsJSON(pactl: pactl) else {
                printError("can't list audio apps (is PulseAudio/PipeWire running? is pactl answering?)")
                return 1
            }
            let inputs = AppStreamCapture.sinkInputs(json: json)
            if inputs.isEmpty { print("no audio apps are playing (start the game or the video, then run this again)"); return 0 }
            media.refresh()
            let keys = media.excludedStreamKeys()
            for i in inputs {
                let excluded = PlayerStreamMap.isExcluded(names: [i.name, i.binary, i.media], keys: keys)
                let label = i.name.isEmpty ? (i.binary.isEmpty ? "?" : i.binary) : i.name
                let detail = [i.binary.isEmpty || i.binary == i.name ? nil : "binary \(i.binary)", i.media.isEmpty ? nil : "\"\(i.media)\""].compactMap { $0 }.joined(separator: ", ")
                let note = excluded ? "   <- the player dialog pause controls: never analyzed" : (i.corked ? "   (paused)" : "")
                print("sourceApp \"\(label)\"\(detail.isEmpty ? "" : "  (\(detail))")\(note)")
            }
            print("\nUse the game's name as dialogPause.sourceApp (--dialog-app).")
            return 0
        } catch { printError("\(error)"); return 2 }
    }

    /// `halltone-linux media pause|play|toggle|next|previous|status`.
    public static func mediaCommand(_ args: [String]) -> Int32 {
        guard let word = args.first, !word.hasPrefix("-") else {
            printError("usage: halltone-linux media pause|play|toggle|next|previous|status")
            return 2
        }
        do {
            let media = try standaloneMedia(Array(args.dropFirst()))
            if word == "status" {
                guard let entries = media.listing() else { printError("can't reach the D-Bus session bus"); return 1 }
                guard let c = entries.first(where: { $0.chosen }) else { print("no player"); return 1 }
                print("\(c.player.status.rawValue.lowercased()): \(c.player.shortName)\(c.player.title.isEmpty ? "" : " - \(c.player.title)")")
                return 0
            }
            let command: MediaCommand
            switch word {
            case "pause": command = .pause
            case "play": command = .play
            case "toggle": command = .playPause
            case "next": command = .next
            case "previous": command = .previous
            default:
                printError("unknown media command \"\(word)\" (pause, play, toggle, next, previous, status)")
                return 2
            }
            guard media.perform(command) else {
                printError("no player to control, or it didn't answer (see `halltone-linux players`)")
                return 1
            }
            print("ok: \(word)")
            return 0
        } catch { printError("\(error)"); return 2 }
    }

    private static func printError(_ text: String) {
        FileHandle.standardError.write(Data("halltone-linux: \(text)\n".utf8))
    }
}

public struct ExitCode: Error, Equatable {
    public let value: Int32
    public init(_ v: Int32) { value = v }
}
