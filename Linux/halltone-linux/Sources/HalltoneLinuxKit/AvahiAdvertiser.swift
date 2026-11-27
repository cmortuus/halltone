import Foundation
import HalltoneCore
#if canImport(os)
import os
#endif
import HalltoneSenderCore

private let log = Logger(subsystem: Constants.logSubsystem, category: "Avahi")

/// Publishes `_halltone._udp` by running `avahi-publish-service` (package avahi-utils) with the
/// same TXT record as the Mac's BonjourAdvertiser: name, v, port, plus `addr` and `ts`.
///
/// avahi-publish-service can't change a TXT record once running, so when the addresses change (or
/// the process dies, e.g. avahi-daemon restarted) it is relaunched. Without the binary the sender
/// still works; the phone just has to add the PC by IP with **+**.
public final class AvahiAdvertiser {
    private let name: String
    private let port: UInt16
    private let baseTXT: [String: String]
    private let addresses: () -> HostAddresses
    private let queue = DispatchQueue(label: "com.halltone.avahi")
    private var timer: DispatchSourceTimer?
    private var process: Process?
    private var published: (addresses: HostAddresses, at: Date)?
    private var lastFailure: Date?
    private var warnedMissing = false
    private var stopped = false

    /// `addresses` is injectable for tests.
    public init(name: String, port: UInt16, txtValues: [String: String],
                addresses: @escaping () -> HostAddresses = NetworkAddresses.current) {
        self.name = name
        self.port = port
        self.baseTXT = txtValues
        self.addresses = addresses
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 5)
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    deinit { shutdown() }

    /// Stops publishing and waits for the helper to exit.
    public func shutdown() {
        queue.sync {
            stopped = true
            timer?.cancel(); timer = nil
            terminate()
        }
    }

    /// The avahi-publish-service arguments for these TXT values.
    static func arguments(name: String, port: UInt16, txt: [String: String], addresses: HostAddresses) -> [String] {
        var values = txt
        if let a = addresses.addr { values["addr"] = a }
        if let ts = addresses.tailscale { values["ts"] = ts }
        let order = ["name", "v", "port", "addr", "ts"]
        let keys = order.filter { values[$0] != nil } + values.keys.filter { !order.contains($0) }.sorted()
        return [name, Constants.serviceType, String(port)] + keys.map { "\($0)=\(values[$0]!)" }
    }

    static func locate(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> String? {
        let dirs = path.split(separator: ":").map(String.init) + ["/usr/bin", "/usr/local/bin"]
        return dirs.map { $0 + "/avahi-publish-service" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func check() {
        guard !stopped else { return }
        let now = addresses()
        if let process, process.isRunning {
            if published?.addresses != now {
                log.notice("addresses changed: \(now.addr ?? "none", privacy: .public), Tailscale \(now.tailscale ?? "none", privacy: .public); republishing")
                terminate()
            } else {
                return
            }
        } else if process != nil {
            // It exited (avahi-daemon restarted or went away).
            process = nil
            lastFailure = Date()
        }
        if let lastFailure, Date().timeIntervalSince(lastFailure) < 5 { return }
        launch(now)
    }

    private func launch(_ now: HostAddresses) {
        guard let exe = Self.locate() else {
            if !warnedMissing {
                warnedMissing = true
                log.error("avahi-publish-service not found (apt install avahi-utils): not advertising; add this PC in the phone app by IP with +")
            }
            return
        }
        let errBox = FDBox()
        do {
            let s = try Spawn.start(exe, Self.arguments(name: name, port: port, txt: baseTXT, addresses: now),
                                    captureStdout: false, captureStderr: true) { [weak self] proc in
                // The child is gone, so stderr hits EOF at once (the deadline covers a stray grandchild).
                let deadline = Date().addingTimeInterval(0.5)
                let text = errBox.take().map { String(decoding: Spawn.drain($0, shouldStop: { Date() > deadline }), as: UTF8.self) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let self, !self.stopped, proc.terminationReason != .uncaughtSignal else { return }
                log.error("avahi-publish-service exited (\(proc.terminationStatus)): \(text, privacy: .public)")
            }
            errBox.set(s.stderr)
            let p = s.process
            process = p
            published = (now, Date())
            warnedMissing = false
            log.notice("advertising \(self.name, privacy: .public) \(Constants.serviceType, privacy: .public) on \(self.port), addr \(now.addr ?? "none", privacy: .public), Tailscale \(now.tailscale ?? "none", privacy: .public)")
        } catch {
            lastFailure = Date()
            log.error("couldn't run avahi-publish-service: \(error)")
        }
    }

    private func terminate() {
        guard let p = process else { return }
        process = nil
        if p.isRunning { p.terminate() }
    }
}

/// Hands the stderr read end from `launch` to the termination handler, which may run on another
/// thread, even before `launch` has stored it. Whoever ends up holding the descriptor closes it:
/// the handler (after reading) or `set` itself when the handler already ran.
private final class FDBox {
    private let lock = NSLock(); private var fd: Int32?; private var taken = false
    func set(_ v: Int32?) {
        lock.lock(); defer { lock.unlock() }
        if taken { if let v { close(v) } } else { fd = v }
    }
    func take() -> Int32? { lock.lock(); defer { lock.unlock() }; taken = true; let v = fd; fd = nil; return v }
}
