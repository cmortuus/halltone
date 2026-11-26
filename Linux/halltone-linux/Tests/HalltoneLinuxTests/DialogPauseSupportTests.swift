import Testing
import Foundation
import HalltoneCore
@testable import HalltoneLinuxKit

@Suite struct DialogPauseSupportTests {
    // MARK: avahi / Mac discovery

    static let avahi = """
    +;wlp2s0;IPv4;Caleb\\039s\\032MacBook;_halltone._udp;local
    =;wlp2s0;IPv4;Caleb\\039s\\032MacBook;_halltone._udp;local;Calebs-MacBook.local;192.168.1.23;47800;"name=Caleb's MacBook" "v=1"
    =;wlp2s0;IPv6;Caleb\\039s\\032MacBook;_halltone._udp;local;Calebs-MacBook.local;fe80::1;47800;"v=1"
    =;enp5s0;IPv4;gaming-pc;_halltone._udp;local;gaming-pc.local;192.168.1.40;47800;"v=1"
    """

    @Test func parsesAvahiBrowseOutput() {
        let s = MacLocator.parseAvahi(Self.avahi)
        #expect(s == [AvahiService(name: "Caleb's MacBook", address: "192.168.1.23", port: 47800),
                      AvahiService(name: "gaming-pc", address: "192.168.1.40", port: 47800)])
    }

    @Test func choosesTheOnlyOtherHost() {
        let s = MacLocator.parseAvahi(Self.avahi)
        #expect(MacLocator.choose(s, selfName: "gaming-pc", localAddresses: []) == .found(s[0]))
        // This PC is recognized by address as well as by name.
        #expect(MacLocator.choose(s, selfName: "Renamed", localAddresses: ["192.168.1.40"]) == .found(s[0]))
        #expect(MacLocator.choose(s, selfName: "Renamed", localAddresses: []) == .ambiguous(["Caleb's MacBook", "gaming-pc"]))
        #expect(MacLocator.choose([], selfName: "x", localAddresses: []) == .none)
        #expect(MacLocator.choose([s[1]], selfName: "GAMING-PC", localAddresses: []) == .none)
    }

    @Test func splitsHostsAndPorts() {
        #expect(MacLocator.splitHostPort("mac.local").host == "mac.local")
        #expect(MacLocator.splitHostPort("mac.local").port == nil)
        #expect(MacLocator.splitHostPort("10.0.0.5:48000") == ("10.0.0.5", 48000))
        #expect(MacLocator.splitHostPort("[fe80::1]:47801") == ("fe80::1", 47801))
        #expect(MacLocator.splitHostPort("fe80::1").host == "fe80::1")
    }

    // MARK: per-application capture

    static let sinkInputs = """
    [
      {"index": 41, "corked": false, "properties": {"application.name": "Discord", "application.process.binary": "Discord"}},
      {"index": 57, "corked": true,  "properties": {"application.name": "Cyberpunk2077.exe", "media.name": "audio stream"}},
      {"index": 58, "corked": false, "properties": {"application.name": "Cyberpunk2077.exe", "media.name": "audio stream"}},
      {"index": 62, "corked": false, "properties": {"application.name": "Firefox", "application.process.binary": "firefox"}}
    ]
    """

    @Test func picksTheRightSinkInput() {
        let json = Data(Self.sinkInputs.utf8)
        #expect(AppStreamCapture.match(json: json, app: "Cyberpunk2077.exe") == 58)   // playing beats corked
        #expect(AppStreamCapture.match(json: json, app: "cyberpunk") == 58)           // substring
        #expect(AppStreamCapture.match(json: json, app: "FIREFOX") == 62)             // binary, any case
        #expect(AppStreamCapture.match(json: json, app: "discord") == 41)
        #expect(AppStreamCapture.match(json: json, app: "Steam") == nil)
        #expect(AppStreamCapture.match(json: Data("not json".utf8), app: "x") == nil)
    }

    // MARK: config

    func resolve(_ file: [String: Any] = [:], _ args: [String] = []) throws -> LinuxConfig {
        var f = file
        f["pairingCode"] = 4321
        return try LinuxConfig.resolve(file: f, flags: Flags.parse(args), hostname: "box")
    }

    @Test func dialogPauseDefaultsToOff() throws {
        let c = try resolve()
        #expect(c.dialogPause == DialogPauseSettings())
        #expect(!c.dialogPause.enabled)
        #expect(c.dialogPause.resumeDelayMs == 1500)
        #expect(c.dialogPause.minDialogMs == 600)
        #expect(c.dialogPause.mac == nil && c.dialogPause.sourceApp == nil)
    }

    @Test func dialogPauseReadsTheConfigFileAndFlagsOverrideIt() throws {
        let file: [String: Any] = ["dialogPause": ["enabled": true, "mac": "Caleb's MacBook", "pairingCode": 7654,
                                                    "resumeDelayMs": 2000, "minDialogMs": 800, "sourceApp": "Cyberpunk2077.exe"]]
        let c = try resolve(file)
        #expect(c.dialogPause.enabled)
        #expect(c.dialogPause.mac == "Caleb's MacBook")
        #expect(c.dialogPause.pairingCode == 7654)
        #expect(c.dialogPause.resumeDelayMs == 2000)
        #expect(c.dialogPause.minDialogMs == 800)
        #expect(c.dialogPause.sourceApp == "Cyberpunk2077.exe")
        let o = try resolve(file, ["--dialog-mac", "10.0.0.5:47800", "--dialog-code", "1111", "--dialog-min-ms", "300",
                                   "--dialog-resume-ms", "1000", "--dialog-app", "Game"])
        #expect(o.dialogPause.mac == "10.0.0.5:47800" && o.dialogPause.pairingCode == 1111)
        #expect(o.dialogPause.minDialogMs == 300 && o.dialogPause.resumeDelayMs == 1000 && o.dialogPause.sourceApp == "Game")
    }

    @Test func enablingNeedsTheMacsPairingCode() throws {
        #expect(throws: ConfigError.self) { try resolve(["dialogPause": ["enabled": true]]) }
        #expect(throws: ConfigError.self) { try resolve([:], ["--dialog-pause"]) }
        let c = try resolve([:], ["--dialog-pause", "--dialog-code", "2222"])
        #expect(c.dialogPause.enabled)
    }

    @Test func badDialogPauseValuesAreRejected() {
        #expect(throws: ConfigError.self) { try resolve(["dialogPause": ["pairingCode": 12]]) }
        #expect(throws: ConfigError.self) { try resolve(["dialogPause": ["minDialogMs": -1]]) }
        #expect(throws: ConfigError.self) { try resolve(["dialogPause": ["resumeDelayMs": "soon"]]) }
        #expect(throws: ConfigError.self) { try resolve(["dialogPause": ["enabled": "yes"]]) }
        #expect(throws: ConfigError.self) { try resolve(["dialogPause": 5]) }
    }

    @Test func wavSourceKeepsThePathsCase() throws {
        let c = try resolve([:], ["--source", "wav:/Tmp/Fixture.WAV"])
        #expect(c.source == .wav("/Tmp/Fixture.WAV"))
        #expect(throws: ConfigError.self) { try resolve([:], ["--source", "wav:"]) }
    }
}
