import Testing
import Foundation
import HalltoneCore
@testable import HalltoneLinuxKit

/// `status --json`: what the tray reads from the control socket.
@Suite(.serialized, .timeLimit(.minutes(2))) struct StatusReportTests {
    static func config(file: [String: Any] = [:], port: UInt16 = UInt16.random(in: 30_000...60_000), socket: String? = nil) throws -> LinuxConfig {
        var f = Flags()
        f.pairingCode = "4242"
        f.name = "Rig"
        f.source = "tone"
        f.noAdvertise = true
        f.port = String(port)
        var c = try LinuxConfig.resolve(file: file, flags: f, hostname: "host")
        c.controlSocket = socket
        return c
    }

    static func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func idleReportHasTheBasics() throws {
        let rt = try LinuxRuntime(config: Self.config())
        let j = try Self.json(rt.handleControl("status --json"))
        #expect(j["name"] as? String == "Rig")
        #expect(j["pairingCode"] as? Int == 4242)
        #expect(j["streaming"] as? Bool == false)
        #expect((j["listeners"] as? [Any])?.isEmpty == true)
        #expect(j["gameMode"] as? Bool == true)          // PCM 2.5 ms is the default
        #expect(j["codec"] as? String == "pcm")
        #expect(j["version"] as? String == App.version)
        #expect((j["dialog"] as? [String: Any])?["configured"] as? Bool == false)
        #expect(j["captureError"] == nil)
        // "json" is the short spelling; the plain status text is unchanged.
        #expect(try Self.json(rt.handleControl("json"))["name"] as? String == "Rig")
        #expect(rt.handleControl("status") == "dialog pause: not configured")
    }

    @Test func codecAndGameModeFollowTheConfig() throws {
        let rt = try LinuxRuntime(config: Self.config(file: ["codec": "opus"]))
        let j = try Self.json(rt.handleControl("status --json"))
        #expect(j["codec"] as? String == "opus")
        #expect(j["gameMode"] as? Bool == false)
        #expect(j["frameMs"] as? Double == 10)
    }

    @Test func dialogPauseSectionReflectsTheSwitch() throws {
        let cfg = try Self.config(file: ["dialogPause": ["target": "local", "sourceApp": "Game", "enabled": false]])
        let rt = try LinuxRuntime(config: cfg)
        var d = try #require(try Self.json(rt.handleControl("status --json"))["dialog"] as? [String: Any])
        #expect(d["configured"] as? Bool == true)
        #expect(d["enabled"] as? Bool == false)
        #expect(d["target"] as? String == "local")
        #expect(d["phase"] as? String == "off")
        _ = rt.handleControl("on")
        d = try #require(try Self.json(rt.handleControl("status --json"))["dialog"] as? [String: Any])
        #expect(d["enabled"] as? Bool == true)
        #expect(d["phase"] as? String == "idle")
        _ = rt.handleControl("off")
        rt.dialog?.stop()
    }

    @Test func overTheSocketWithAListener() throws {
        let socket = NSTemporaryDirectory() + "ht-\(UInt32.random(in: 0...999_999)).sock"
        let port = UInt16.random(in: 30_000...60_000)
        let rt = try LinuxRuntime(config: Self.config(port: port, socket: socket))
        try rt.start()
        defer { rt.stop() }

        let idle = ControlSocket.request(path: socket, line: "status --json")
        let j0 = try Self.json(try #require(idle.reply))
        #expect(j0["streaming"] as? Bool == false)

        let client = TestClient(port: port)
        var joined = false
        for _ in 0..<25 where !joined {
            client.send(.subscribe(pairingCode: 4242, deviceName: "Pixel Phone", deviceID: "status-test"))
            joined = (client.receive(timeout: 0.4, until: { p -> Bool? in
                if case .subscribeAck = p.message { return true }
                return nil
            }) as Bool?) != nil
        }
        #expect(joined)
        var listeners: [[String: Any]] = []
        for _ in 0..<20 where listeners.isEmpty {
            let r = ControlSocket.request(path: socket, line: "status --json")
            let j = try Self.json(try #require(r.reply))
            listeners = j["listeners"] as? [[String: Any]] ?? []
            if listeners.isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        }
        #expect(listeners.first?["name"] as? String == "Pixel Phone")
        #expect(listeners.first?["address"] is String)
        let j1 = try Self.json(try #require(ControlSocket.request(path: socket, line: "status --json").reply))
        #expect(j1["streaming"] as? Bool == true)
    }
}
