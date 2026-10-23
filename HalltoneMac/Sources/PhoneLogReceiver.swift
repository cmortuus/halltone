import Foundation
import Network
import os
import HalltoneCore

private let log = Logger(subsystem: Constants.logSubsystem, category: "PhoneLogs")

/// Accepts diagnostics logs that phones upload once theirs reach 25 MB, so the history outlives
/// the phone's own rotation. Files land in ~/Library/Logs/Halltone/Phones/<phone>/ and the oldest
/// are deleted beyond 5 GB.
///
/// Protocol (TCP, one file per connection): a header line
/// `HTLOG1 <pairing code> <byte count> <base64 phone name>\n`, then exactly that many bytes. The
/// Mac answers `OK\n` once the file is safely on disk, or `NO <reason>\n`.
final class PhoneLogReceiver {
    static let root = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Halltone/Phones", isDirectory: true)
    private static let maxFileBytes = 64 << 20
    private static let maxTotalBytes: Int64 = 5 << 30

    private let queue = DispatchQueue(label: "com.halltone.phonelogs")
    private var listener: NWListener?
    private let lock = NSLock()
    private var code: UInt32 = 0
    /// The Mac's current pairing code; uploads must carry it.
    var pairingCode: UInt32 {
        get { lock.lock(); defer { lock.unlock() }; return code }
        set { lock.lock(); code = newValue; lock.unlock() }
    }

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Constants.logUploadPort) else { return }
        do {
            let l = try NWListener(using: .tcp, on: port)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { st in
                if case .failed(let e) = st { log.error("log upload listener failed: \(e)") }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            log.error("log upload listener: \(error)")
        }
    }

    func stop() { listener?.cancel(); listener = nil }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        // Drop connections that stall (or never send a header) instead of holding them open.
        queue.asyncAfter(deadline: .now() + 600) { c.cancel() }
        readHeader(c, buffer: Data())
    }

    private func readHeader(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 512) { [self] data, _, done, err in
            var buf = buffer
            if let data { buf.append(data) }
            guard let nl = buf.firstIndex(of: 0x0A) else {
                if done || err != nil || buf.count > 512 { c.cancel() } else { readHeader(c, buffer: buf) }
                return
            }
            let parts = String(decoding: buf[..<nl], as: UTF8.self).split(separator: " ")
            guard parts.count == 4, parts[0] == "HTLOG1", let code = UInt32(parts[1]), let size = Int(parts[2]),
                  let nameData = Data(base64Encoded: String(parts[3])) else { return reply(c, "NO header") }
            guard code == pairingCode else { return reply(c, "NO code") }
            guard size > 0, size <= Self.maxFileBytes else { return reply(c, "NO size") }
            let name = Self.folderName(String(decoding: nameData, as: UTF8.self))
            let dir = Self.root.appendingPathComponent(name, isDirectory: true)
            let stamp = Self.stampFormatter.string(from: Date())
            let part = dir.appendingPathComponent("\(stamp).log.part")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: part.path, contents: nil)
                let h = try FileHandle(forWritingTo: part)
                let first = buf[buf.index(after: nl)...]
                if !first.isEmpty { try h.write(contentsOf: first) }
                readBody(c, handle: h, part: part, remaining: size - first.count)
            } catch {
                log.error("log upload: \(error)")
                reply(c, "NO disk")
            }
        }
    }

    private func readBody(_ c: NWConnection, handle h: FileHandle, part: URL, remaining: Int) {
        guard remaining > 0 else { return finish(c, handle: h, part: part) }
        c.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 1 << 20)) { [self] data, _, done, err in
            do {
                if let data, !data.isEmpty { try h.write(contentsOf: data) }
                let left = remaining - (data?.count ?? 0)
                if left > 0, done || err != nil {
                    try? h.close(); try? FileManager.default.removeItem(at: part); c.cancel()
                    return
                }
                readBody(c, handle: h, part: part, remaining: left)
            } catch {
                try? h.close(); try? FileManager.default.removeItem(at: part)
                reply(c, "NO disk")
            }
        }
    }

    private func finish(_ c: NWConnection, handle h: FileHandle, part: URL) {
        do {
            try h.close()
            let final = part.deletingPathExtension()
            try FileManager.default.moveItem(at: part, to: final)
            log.notice("saved phone log \(final.path, privacy: .public)")
            reply(c, "OK")
            prune()
        } catch {
            try? FileManager.default.removeItem(at: part)
            reply(c, "NO disk")
        }
    }

    private func reply(_ c: NWConnection, _ text: String) {
        c.send(content: Data((text + "\n").utf8), completion: .contentProcessed { _ in c.cancel() })
    }

    /// Oldest files first until everything fits in 5 GB.
    private func prune() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: Self.root, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        for case let url as URL in walker where url.pathExtension == "log" {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            files.append((url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        for f in files.sorted(by: { $0.date < $1.date }) where total > Self.maxTotalBytes {
            try? FileManager.default.removeItem(at: f.url)
            total -= f.size
            log.notice("deleted old phone log \(f.url.lastPathComponent, privacy: .public)")
        }
    }

    private static func folderName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "iPhone" : String(cleaned.prefix(64))
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()
}
