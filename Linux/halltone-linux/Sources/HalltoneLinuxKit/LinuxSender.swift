import Foundation
import HalltoneCore
import HalltoneSenderCore

/// The sender on Linux: `SenderCore` with Avahi advertising and MPRIS media controls.
///
/// With a `MediaController`: STATUS reports `controlsAvailable` when an MPRIS player exists and
/// whether it is playing; CONTROL play/pause/next/previous (and explicit pause/play) drive the
/// chosen player; REMOTE_CONTROL pauses and resumes it through `RemoteControlCoordinator`
/// (unless `allowRemoteControl` is off). Without one (no D-Bus), controls are unavailable and
/// REMOTE_CONTROL answers `disabled`. Holds stay a Mac-side feature; "user at the PC" comes from `PresenceMonitor`.
public final class LinuxSender: SenderCore {
    public let media: MediaController?
    public let presence: PresenceMonitor?

    public override convenience init(config: Config, source: @escaping () -> AudioSource) {
        self.init(config: config, media: nil, allowRemoteControl: false, source: source)
    }

    public init(config: Config, media: MediaController?, presence: PresenceMonitor? = nil, allowRemoteControl: Bool,
                source: @escaping () -> AudioSource) {
        self.media = media
        self.presence = presence
        super.init(config: config, source: source)
        // "User at the PC" / "recent input" (#34): cached reads, so the sender's queue never waits on D-Bus.
        if let presence {
            userAtMac = { presence.userAtPC() }
            userInputRecent = { presence.inputRecent() }
        }
        guard let media else {
            controlsAvailable = { false }
            remoteControlEnabled = { false }
            return
        }
        controlsAvailable = { media.controlsAvailableCached() }
        playbackState = { media.peekPlayingCached() }
        remoteEnvironment = media
        remoteControlEnabled = { allowRemoteControl }
        // Media keys run on the MPRIS queue and the receive path waits at most 0.5 s for the answer:
        // a wedged bus must not hold up the receive thread (an unanswered key counts as sent).
        let mediaKeys = DispatchQueue(label: "com.halltone.mpris.keys")
        onControl = { command in
            let key: MediaCommand
            switch command {
            case .playPause: key = .playPause
            case .next: key = .next
            case .previous: key = .previous
            case .pause: key = .pause
            case .play: key = .play
            default: return true // settings (holds, listening) aren't media keys
            }
            let done = DispatchSemaphore(value: 0)
            let box = ResultBox()
            mediaKeys.async { box.set(media.perform(key)); done.signal() }
            return done.wait(timeout: .now() + 0.5) == .success ? box.value : true
        }
    }

    public override func makeAdvertiser(txtValues: [String: String], queue: DispatchQueue) -> AnyObject? {
        AvahiAdvertiser(name: config.macName, port: config.port, txtValues: txtValues)
    }
}

/// Builds and runs the sender for a resolved config.
public final class LinuxRuntime {
    public let config: LinuxConfig
    public let sender: LinuxSender
    /// Dialog pause (detector + REMOTE_CONTROL client or local MPRIS); nil unless `dialogPause.target`
    /// is "local" or `dialogPause.pairingCode` (the Mac's) is set.
    public let dialog: DialogPauseService?
    /// MPRIS media control; shared with dialog pause on this PC.
    public let media: MediaController
    /// Idle / lock state of the desktop, reported in STATUS as the Mac's "user at Mac" flags.
    public let presence: PresenceMonitor
    private var control: ControlServer?
    let statsBox = StatsBox()

    public init(config: LinuxConfig) throws {
        self.config = config
        let fragment = config.frameSamples
        let kind = config.source
        let tone = config.gameMode ? 128 : 480
        let device = config.pulseDevice
        let media = MediaController(pin: config.media.player, ignore: config.media.ignore)
        self.media = media
        let box = statsBox
        let presence = PresenceMonitor(wanted: { !box.get().subscribers.isEmpty })
        self.presence = presence
        let service = config.dialogPause.isConfigured
            ? DialogPauseService(settings: config.dialogPause, selfName: config.name, media: media) : nil
        dialog = service
        let allow = config.allowRemoteControl
        let tap = service?.captureTap
        switch kind {
        case .tone:
            sender = LinuxSender(config: config.senderConfig(), media: media, presence: presence, allowRemoteControl: allow) { ToneSource(blockFrames: tone) }
        case .wav(let path):
            _ = try WavSource(path: path)   // fail at start-up, not at the first subscriber
            let block = fragment
            sender = LinuxSender(config: config.senderConfig(), media: media, presence: presence, allowRemoteControl: allow) {
                // A fresh player each time capture starts; the file was checked above.
                let wav: AudioSource? = try? WavSource(path: path, blockFrames: block, tap: tap)
                return wav ?? ToneSource(amplitude: 0)
            }
        case .pulse:
            #if canImport(CPulseSimple)
            sender = LinuxSender(config: config.senderConfig(), media: media, presence: presence, allowRemoteControl: allow) {
                PulseSource(device: device, fragmentFrames: fragment, tap: tap)
            }
            #else
            _ = (fragment, device, tap)
            throw ConfigError("PulseAudio capture is only available on Linux; use --source tone here")
            #endif
        }
        sender.onStats = { box.set($0) }
    }

    public func start() throws {
        media.startPolling()
        try sender.start()
        dialog?.start()
        let server = ControlServer(path: config.controlSocket ?? ControlSocket.defaultPath()) { [weak self] in
            self?.handleControl($0) ?? "error: stopping"
        }
        if let problem = server.start() {
            FileHandle.standardError.write(Data("halltone-linux: warning: \(problem)\n".utf8))
        } else {
            control = server
        }
    }

    public func stop() {
        control?.stop()
        media.stopPolling()
        dialog?.stop()    // asks the Mac (or resumes the local player) if it was paused for us
        sender.stop()
    }

    /// SIGUSR1: flips dialog pause; false when it isn't configured.
    @discardableResult
    public func toggleDialog() -> Bool {
        guard let dialog else { return false }
        dialog.toggle()
        return true
    }

    /// One control-socket line (`on`, `off`, `toggle`, `status`) → the reply.
    public func handleControl(_ command: String) -> String {
        let unconfigured = "error: dialog pause is not configured: set dialogPause.pairingCode (the Mac's pairing code) or dialogPause.target \"local\" in the config and restart"
        switch command {
        case "on", "off":
            guard let dialog else { return unconfigured }
            dialog.setEnabled(command == "on")
            return "ok: dialog pause \(command)"
        case "toggle":
            guard let dialog else { return unconfigured }
            dialog.toggle()
            return "ok: dialog pause \(dialog.controller.isEnabled ? "on" : "off")"
        case "status --json", "json":
            return statusJSON()
        case "status", "":
            return dialog?.statusText() ?? "dialog pause: not configured"
        default:
            return "error: unknown command \"\(command)\" (on, off, toggle, status, status --json)"
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock(); private var v = true
    func set(_ x: Bool) { lock.lock(); v = x; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}
