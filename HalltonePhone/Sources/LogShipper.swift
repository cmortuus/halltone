import Foundation
import Network
import HalltoneCore

/// Diagnostics logs that reached 25 MB wait in Documents/LogOutbox until the phone is connected
/// to a Mac, which keeps them (PhoneLogReceiver on the Mac). History then outlives the phone's
/// own storage, and the outbox is capped so a phone that never meets its Mac doesn't fill up.
final class LogShipper {
    static let shared = LogShipper()
    static let outbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LogOutbox", isDirectory: true)
    private static let maxOutboxBytes = 100 << 20

    struct Target { var host: String; var pairingCode: UInt32; var deviceName: String }

    private let queue = DispatchQueue(label: "com.halltone.logshipper")
    private var sending = false
    private let lock = NSLock()
    private var current: Target?
    /// The Mac we're subscribed to (nil while not connected). Setting it sends what's waiting.
    var target: Target? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock(); flush() }
    }

    /// Called (on DiagFile's queue) with a full log: move it into the outbox.
    func enqueue(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.outbox, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        try? fm.moveItem(at: url, to: Self.outbox.appendingPathComponent("halltone-\(f.string(from: Date())).log"))
        trimOutbox()
        flush()
    }

    /// Send whatever is waiting to the current Mac, oldest first, one at a time.
    private func flush() {
        queue.async { [self] in
            guard !sending, let t = target, let next = pending().first else { return }
            sending = true
            send(next, host: t.host, code: t.pairingCode, name: t.deviceName) { [self] ok in
                queue.async { [self] in
                    sending = false
                    if ok {
                        try? FileManager.default.removeItem(at: next)
                        diag("uploaded \(next.lastPathComponent) to the Mac")
                        flush()
                    }
                }
            }
        }
    }

    private func pending() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.outbox, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func trimOutbox() {
        var files = pending()
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        var total = files.reduce(0) { $0 + size($1) }
        while total > Self.maxOutboxBytes, !files.isEmpty {
            let oldest = files.removeFirst()
            total -= size(oldest)
            try? FileManager.default.removeItem(at: oldest)
        }
    }

    private func send(_ file: URL, host: String, code: UInt32, name: String, done: @escaping (Bool) -> Void) {
        guard let body = try? Data(contentsOf: file), !body.isEmpty,
              let port = NWEndpoint.Port(rawValue: Constants.logUploadPort) else { return done(false) }
        let params = NWParameters.tcp
        // Bulk transfer: stay out of the way of the audio stream on the same Wi-Fi.
        params.serviceClass = .background
        let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        var finished = false
        let finish: (Bool) -> Void = { ok in
            guard !finished else { return }
            finished = true
            c.cancel()
            done(ok)
        }
        c.stateUpdateHandler = { st in
            switch st {
            case .ready:
                let header = "HTLOG1 \(code) \(body.count) \(Data(name.utf8).base64EncodedString())\n"
                c.send(content: Data(header.utf8) + body, completion: .contentProcessed { err in
                    if err != nil { return finish(false) }
                    c.receive(minimumIncompleteLength: 2, maximumLength: 64) { data, _, _, _ in
                        let answer = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        if !answer.hasPrefix("OK") { diag("log upload refused: \(answer.trimmingCharacters(in: .whitespacesAndNewlines))") }
                        finish(answer.hasPrefix("OK"))
                    }
                })
            case .failed, .waiting:
                finish(false)
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 300) { finish(false) }
    }
}
