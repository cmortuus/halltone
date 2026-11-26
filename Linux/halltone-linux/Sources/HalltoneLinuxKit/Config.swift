import Foundation
import HalltoneCore
import HalltoneSenderCore

public enum SourceKind: String { case pulse, tone }

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

/// Command-line flags. Every one overrides the same setting in the config file.
public struct Flags: Equatable {
    public var configPath: String?
    public var name: String?
    public var pairingCode: String?
    public var codec: String?
    public var frameMs: String?
    public var port: String?
    public var source: String?
    public var pulseDevice: String?
    public var noAdvertise = false
    public var simulatedLoss: String?
    public var simulatedJitterMs: String?
    public var help = false
    public var version = false

    public init() {}

    public static let usage = """
    halltone-linux: streams this PC's audio to the Halltone app on your iPhone.

    Usage: halltone-linux [options]

      --name <text>        Name the phone shows (default: this PC's hostname)
      --code <1000-9999>   Pairing code (default: generated on first run, saved in the config)
      --codec pcm|opus     pcm (default: lowest latency) or opus (less Wi-Fi bandwidth)
      --frame-ms 2.5|5     PCM frame size (default 2.5 = Game mode); Opus is always 10
      --port <n>           UDP port (default 47800)
      --source pulse|tone  Audio source: PulseAudio/PipeWire monitor (default) or a test tone
      --device <name>      PulseAudio source to capture (default @DEFAULT_MONITOR@)
      --no-advertise       Don't publish over Bonjour/Avahi (add the PC by IP in the app)
      --config <path>      Config file (default ~/.config/halltone/config.json)
      --simulate-loss <p>  Test hook: drop this fraction (0-1) of outgoing audio packets
      --simulate-jitter-ms <ms>  Test hook: delay outgoing audio by up to this many ms
      --version, --help
    """

    public static func parse(_ args: [String]) throws -> Flags {
        var f = Flags()
        var i = 0
        func value(_ flag: String, _ inline: String?) throws -> String {
            if let inline { return inline }
            i += 1
            guard i < args.count else { throw ConfigError("\(flag) needs a value") }
            return args[i]
        }
        while i < args.count {
            var arg = args[i]
            var inline: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                inline = String(arg[arg.index(after: eq)...])
                arg = String(arg[..<eq])
            }
            switch arg {
            case "--config": f.configPath = try value(arg, inline)
            case "--name": f.name = try value(arg, inline)
            case "--code": f.pairingCode = try value(arg, inline)
            case "--codec": f.codec = try value(arg, inline)
            case "--frame-ms": f.frameMs = try value(arg, inline)
            case "--port": f.port = try value(arg, inline)
            case "--source": f.source = try value(arg, inline)
            case "--device": f.pulseDevice = try value(arg, inline)
            case "--simulate-loss": f.simulatedLoss = try value(arg, inline)
            case "--simulate-jitter-ms": f.simulatedJitterMs = try value(arg, inline)
            case "--no-advertise": f.noAdvertise = true
            case "--help", "-h": f.help = true
            case "--version": f.version = true
            default: throw ConfigError("unknown option \(args[i]) (see --help)")
            }
            i += 1
        }
        return f
    }
}

/// The effective settings after merging defaults, the config file and flags.
public struct LinuxConfig: Equatable {
    public var name: String
    public var pairingCode: UInt32
    public var codec: CodecID
    public var frameMs: Double
    public var port: UInt16
    public var source: SourceKind
    public var pulseDevice: String
    public var advertise: Bool
    public var simulatedLoss: Double
    public var simulatedJitterMs: Double

    public static let defaultPulseDevice = "@DEFAULT_MONITOR@"
    public static let pairingCodeRange: ClosedRange<UInt32> = 1000...9999

    /// Game mode (PCM in 2.5 ms frames) when the config asks for PCM at 2.5 ms.
    public var gameMode: Bool { codec == .pcm16 && frameMs <= 2.5 }

    /// Samples per frame on the wire.
    public var frameSamples: Int { senderConfig().frameSamples }

    public func senderConfig() -> SenderCore.Config {
        var c = SenderCore.Config()
        c.port = port
        c.codec = codec
        c.gameMode = gameMode
        c.pairingCode = pairingCode
        c.macName = name
        c.advertise = advertise
        c.simulatedLoss = simulatedLoss
        c.simulatedJitterMs = simulatedJitterMs
        return c
    }

    /// Merges `file` (parsed JSON; keys name, pairingCode, codec, frameMs, port, advertise,
    /// pulseDevice) with `flags`: flags win, then the file, then the defaults. A missing pairing
    /// code throws: the caller generates and saves one first (`ConfigStore.prepare`).
    public static func resolve(file: [String: Any], flags: Flags, hostname: String) throws -> LinuxConfig {
        func string(_ key: String) throws -> String? {
            guard let v = file[key] else { return nil }
            if let s = v as? String { return s }
            if let i = v as? Int { return String(i) }
            if let d = v as? Double { return String(d) }
            throw ConfigError("config.json: \"\(key)\" must be a string or number")
        }
        func number(_ text: String?, _ what: String) throws -> Double? {
            guard let text else { return nil }
            guard let d = Double(text.trimmingCharacters(in: .whitespaces)) else {
                throw ConfigError("\(what) must be a number, not \"\(text)\"")
            }
            return d
        }

        // Name.
        var name = try flags.name ?? string("name") ?? ""
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = hostname.split(separator: ".").first.map(String.init) ?? hostname
        }
        if name.isEmpty { name = "Linux PC" }

        // Pairing code.
        guard let codeText = try flags.pairingCode ?? string("pairingCode") else {
            throw ConfigError("no pairing code")
        }
        guard let codeValue = UInt32(codeText.trimmingCharacters(in: .whitespaces)),
              pairingCodeRange.contains(codeValue) else {
            throw ConfigError("the pairing code must be 4 digits (1000-9999), not \"\(codeText)\"")
        }

        // Codec and frame size.
        let codecText = try (flags.codec ?? string("codec") ?? "pcm").lowercased()
        let codec: CodecID
        switch codecText {
        case "pcm", "pcm16": codec = .pcm16
        case "opus": codec = .opus
        default: throw ConfigError("codec must be \"pcm\" or \"opus\", not \"\(codecText)\"")
        }
        let frameMsGiven = try number(flags.frameMs, "--frame-ms") ?? number(string("frameMs"), "config.json: frameMs")
        let frameMs: Double
        switch codec {
        case .pcm16:
            frameMs = frameMsGiven ?? 2.5
            guard frameMs == 2.5 || frameMs == 5 else {
                throw ConfigError("PCM frame size must be 2.5 or 5 ms, not \(frameMs)")
            }
        case .opus:
            frameMs = frameMsGiven ?? 10
            guard frameMs == 10 else { throw ConfigError("Opus frames are always 10 ms, not \(frameMs)") }
        }

        // Port.
        let portValue = try number(flags.port, "--port") ?? number(string("port"), "config.json: port") ?? Double(Constants.defaultPort)
        guard portValue == portValue.rounded(), (1...65535).contains(portValue) else {
            throw ConfigError("port must be 1-65535, not \(portValue)")
        }

        // Source and device.
        let sourceText = (flags.source ?? "pulse").lowercased()
        guard let source = SourceKind(rawValue: sourceText) else {
            throw ConfigError("source must be \"pulse\" or \"tone\", not \"\(sourceText)\"")
        }
        let device = try flags.pulseDevice ?? string("pulseDevice") ?? defaultPulseDevice

        // Advertising.
        var advertise = true
        if let v = file["advertise"] {
            guard let b = v as? Bool else { throw ConfigError("config.json: \"advertise\" must be true or false") }
            advertise = b
        }
        if flags.noAdvertise { advertise = false }

        let loss = try number(flags.simulatedLoss, "--simulate-loss") ?? 0
        let jitter = try number(flags.simulatedJitterMs, "--simulate-jitter-ms") ?? 0
        guard (0...1).contains(loss), jitter >= 0 else { throw ConfigError("--simulate-loss is 0-1, --simulate-jitter-ms is >= 0") }

        return LinuxConfig(name: name, pairingCode: codeValue, codec: codec, frameMs: frameMs,
                           port: UInt16(portValue), source: source, pulseDevice: device,
                           advertise: advertise, simulatedLoss: loss, simulatedJitterMs: jitter)
    }
}

/// `~/.config/halltone/config.json`: loaded at start; a first run writes the defaults with a
/// freshly generated pairing code so the same code is used on every later start.
public enum ConfigStore {
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let base: String
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            base = xdg
        } else {
            let home = environment["HOME"] ?? NSHomeDirectory()
            base = home + "/.config"
        }
        return base + "/halltone/config.json"
    }

    /// The file's JSON object; empty when the file doesn't exist.
    public static func load(path: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch {
            throw ConfigError("\(path) is not valid JSON: \(error.localizedDescription)")
        }
        guard let dict = object as? [String: Any] else { throw ConfigError("\(path) must contain a JSON object") }
        return dict
    }

    public static func save(_ values: [String: Any], path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    public struct Prepared {
        public var config: LinuxConfig
        public var path: String
        /// A pairing code was generated (and saved) by this run.
        public var generatedCode: Bool
    }

    /// Loads the config, generating and saving a pairing code when there is none (unless one was
    /// given on the command line), and resolves the effective settings.
    public static func prepare(flags: Flags, hostname: String,
                               environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Prepared {
        let path = flags.configPath ?? defaultPath(environment: environment)
        var file = try load(path: path)
        var generated = false
        if flags.pairingCode == nil, file["pairingCode"] == nil {
            let code = UInt32.random(in: LinuxConfig.pairingCodeRange)
            let fresh = file.isEmpty
            file["pairingCode"] = Int(code)
            if fresh {
                // Spell the defaults out so the file documents what can be changed.
                file["name"] = hostname.split(separator: ".").first.map(String.init) ?? hostname
                file["codec"] = "pcm"
                file["frameMs"] = 2.5
                file["port"] = Int(Constants.defaultPort)
            }
            do { try save(file, path: path) } catch {
                // A read-only home shouldn't stop the stream; the code just changes next start.
                FileHandle.standardError.write(Data("warning: couldn't save \(path): \(error)\n".utf8))
            }
            generated = true
        }
        let config = try LinuxConfig.resolve(file: file, flags: flags, hostname: hostname)
        return Prepared(config: config, path: path, generatedCode: generated)
    }
}
