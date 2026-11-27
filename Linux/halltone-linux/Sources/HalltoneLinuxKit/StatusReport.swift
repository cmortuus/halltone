import Foundation
import HalltoneCore
import HalltoneSenderCore

/// The latest sender stats, kept for the control socket (`SenderCore.stats` belongs to the sender's
/// queue; `onStats` hands out copies).
final class StatsBox {
    private let lock = NSLock()
    private var value = SenderCore.Stats()
    func set(_ s: SenderCore.Stats) { lock.lock(); value = s; lock.unlock() }
    func get() -> SenderCore.Stats { lock.lock(); defer { lock.unlock() }; return value }
}

extension LinuxRuntime {
    /// The reply to `status --json`: everything the tray icon's menu shows, as one JSON object.
    /// The tray (`Linux/tray/halltone-tray`) is its only reader; add keys freely, never rename them.
    public func statusJSON() -> String {
        let s = statsBox.get()
        var o: [String: Any] = [
            "version": App.version,
            "name": config.name,
            "pairingCode": Int(config.pairingCode),
            "port": Int(config.port),
            "codec": config.codec == .opus ? "opus" : "pcm",
            "frameMs": config.frameMs,
            "gameMode": config.gameMode,
            "source": config.source.name,
            "allowRemoteControl": config.allowRemoteControl,
            "listening": s.listening,
            "capturing": s.capturing,
            "streaming": !s.subscribers.isEmpty,
            "kbps": s.kilobitsPerSecond,
            "pps": s.packetsPerSecond,
            "listeners": s.subscribers.map { l -> [String: Any] in
                ["name": l.name, "address": l.id, "bufferMs": l.bufferMs, "lossPermille": l.lossPermille]
            },
        ]
        if let e = s.captureError { o["captureError"] = e }

        var d: [String: Any] = ["configured": dialog != nil]
        if let dialog {
            d["enabled"] = dialog.controller.isEnabled
            d["target"] = dialog.settings.target == .local ? "local" : "mac"
            d["phase"] = dialog.controller.phaseWord
            d["loopGuardTripped"] = dialog.loopGuard?.isTripped ?? false
        }
        o["dialog"] = d

        var m: [String: Any] = ["available": media.controlsAvailableCached(demand: false, maxAge: 10)]
        if let p = media.chosen() {
            m["player"] = p.shortName
            m["status"] = p.status.rawValue.lowercased()
            if !p.title.isEmpty { m["title"] = p.title }
        }
        o["media"] = m

        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
