import Testing
import Foundation
import HalltoneCore
@testable import HalltoneLinuxKit

@Suite struct ConfigTests {
    static func tempPath() -> String {
        NSTemporaryDirectory() + "halltone-test-\(UUID().uuidString)/config.json"
    }

    @Test func defaultsAreGameModePcm() throws {
        var flags = Flags()
        flags.pairingCode = "4321"
        let c = try LinuxConfig.resolve(file: [:], flags: flags, hostname: "gamer-pc.local")
        #expect(c.name == "gamer-pc")
        #expect(c.pairingCode == 4321)
        #expect(c.codec == .pcm16)
        #expect(c.frameMs == 2.5)
        #expect(c.gameMode)
        #expect(c.frameSamples == 120)
        #expect(c.port == 47800)
        #expect(c.source == .pulse)
        #expect(c.pulseDevice == "@DEFAULT_MONITOR@")
        #expect(c.advertise)
        let sc = c.senderConfig()
        #expect(sc.effectiveCodec == .pcm16)
        #expect(sc.pairingCode == 4321)
        #expect(sc.macName == "gamer-pc")
    }

    @Test func fileValuesApplyAndFlagsOverrideThem() throws {
        let file: [String: Any] = ["name": "Den PC", "pairingCode": 1234, "codec": "opus", "port": 50000,
                                   "advertise": false, "pulseDevice": "alsa_output.x.monitor"]
        let c = try LinuxConfig.resolve(file: file, flags: Flags(), hostname: "h")
        #expect(c.name == "Den PC")
        #expect(c.codec == .opus)
        #expect(c.frameMs == 10)
        #expect(!c.gameMode)
        #expect(c.frameSamples == Constants.opusFrameSamples)
        #expect(c.port == 50000)
        #expect(!c.advertise)
        #expect(c.pulseDevice == "alsa_output.x.monitor")

        var f = try Flags.parse(["--name", "Flag PC", "--code=9999", "--codec", "pcm", "--frame-ms", "5", "--port", "47801"])
        f.noAdvertise = false
        let o = try LinuxConfig.resolve(file: file, flags: f, hostname: "h")
        #expect(o.name == "Flag PC")
        #expect(o.pairingCode == 9999)
        #expect(o.codec == .pcm16)
        #expect(o.frameMs == 5)
        #expect(!o.gameMode)
        #expect(o.frameSamples == Constants.pcmFrameSamples)
        #expect(o.port == 47801)
        #expect(!o.advertise) // still off: the file says so and no flag turns it on
    }

    @Test func invalidValuesAreRejected() {
        func fails(_ args: [String], file: [String: Any] = ["pairingCode": 1234]) -> Bool {
            do {
                let f = try Flags.parse(args)
                _ = try LinuxConfig.resolve(file: file, flags: f, hostname: "h")
                return false
            } catch { return true }
        }
        #expect(fails(["--code", "12"]))
        #expect(fails(["--code", "abcd"]))
        #expect(fails(["--codec", "flac"]))
        #expect(fails(["--frame-ms", "7"]))
        #expect(fails(["--codec", "opus", "--frame-ms", "5"]))
        #expect(fails(["--port", "0"]))
        #expect(fails(["--port", "70000"]))
        #expect(fails(["--source", "alsa"]))
        #expect(fails(["--bogus"]))
        #expect(fails(["--name"]))
        #expect(fails([], file: [:])) // no pairing code
    }

    @Test func firstRunGeneratesAndSavesAPairingCode() throws {
        let path = Self.tempPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        var flags = Flags()
        flags.configPath = path
        let first = try ConfigStore.prepare(flags: flags, hostname: "box.lan")
        #expect(first.generatedCode)
        #expect(LinuxConfig.pairingCodeRange.contains(first.config.pairingCode))
        #expect(first.config.name == "box")
        let saved = try ConfigStore.load(path: path)
        #expect(saved["pairingCode"] as? Int == Int(first.config.pairingCode))
        #expect(saved["codec"] as? String == "pcm")
        #expect(saved["port"] as? Int == 47800)

        // Second start reuses the saved code.
        let second = try ConfigStore.prepare(flags: flags, hostname: "box.lan")
        #expect(!second.generatedCode)
        #expect(second.config.pairingCode == first.config.pairingCode)
    }

    @Test func existingFileWithoutACodeKeepsItsOtherKeys() throws {
        let path = Self.tempPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try ConfigStore.save(["name": "Keep Me", "custom": "yes"], path: path)
        var flags = Flags()
        flags.configPath = path
        let p = try ConfigStore.prepare(flags: flags, hostname: "h")
        #expect(p.generatedCode)
        #expect(p.config.name == "Keep Me")
        let saved = try ConfigStore.load(path: path)
        #expect(saved["custom"] as? String == "yes")
        #expect(saved["pairingCode"] != nil)
    }

    @Test func malformedConfigIsAnError() throws {
        let path = Self.tempPath()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: path))
        var flags = Flags()
        flags.configPath = path
        #expect(throws: ConfigError.self) { try ConfigStore.prepare(flags: flags, hostname: "h") }
    }

    @Test func configPathHonorsXdg() {
        #expect(ConfigStore.defaultPath(environment: ["HOME": "/home/u"]) == "/home/u/.config/halltone/config.json")
        #expect(ConfigStore.defaultPath(environment: ["HOME": "/home/u", "XDG_CONFIG_HOME": "/x"]) == "/x/halltone/config.json")
    }
}

@Suite struct MediaConfigTests {
    private func resolve(_ file: [String: Any] = [:], _ tweak: (inout Flags) -> Void = { _ in }) throws -> LinuxConfig {
        var flags = Flags(); flags.pairingCode = "4321"; tweak(&flags)
        return try LinuxConfig.resolve(file: file, flags: flags, hostname: "h")
    }

    @Test func defaultsAllowEverythingAndPinNothing() throws {
        let c = try resolve()
        #expect(c.media.player == nil)
        #expect(c.media.ignore.isEmpty)
        #expect(c.allowRemoteControl)
    }

    @Test func fileAndFlagsSetPinIgnoreAndRemoteControl() throws {
        var c = try resolve(["media": ["player": " firefox ", "ignore": ["steam", " "]], "allowRemoteControl": false])
        #expect(c.media.player == "firefox")
        #expect(c.media.ignore == ["steam"])
        #expect(!c.allowRemoteControl)
        c = try resolve(["media": ["player": "firefox"]]) { $0.mediaPlayer = "mpv"; $0.mediaIgnore = "a, b" }
        #expect(c.media.player == "mpv")
        #expect(c.media.ignore == ["a", "b"])
        c = try resolve { $0.noRemoteControl = true }
        #expect(!c.allowRemoteControl)
        #expect(try Flags.parse(["--media-player", "vlc", "--media-ignore=x,y", "--no-remote-control"]).mediaIgnore == "x,y")
    }

    @Test func badTypesAreRejected() {
        #expect(throws: ConfigError.self) { try resolve(["media": "firefox"]) }
        #expect(throws: ConfigError.self) { try resolve(["media": ["ignore": "steam"]]) }
        #expect(throws: ConfigError.self) { try resolve(["allowRemoteControl": "yes"]) }
    }
}
