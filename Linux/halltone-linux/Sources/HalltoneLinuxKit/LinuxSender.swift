import Foundation
import HalltoneCore
import HalltoneSenderCore

/// The sender on Linux: `SenderCore` with Avahi advertising and no media controls.
///
/// STATUS is still sent (so the phone sees `controlsAvailable` false and whether audio is
/// playing); CONTROL media keys are ignored; REMOTE_CONTROL is reported as disabled because there
/// is nothing to press play/pause with. Holds and "user at the PC" stay Mac-side features.
public final class LinuxSender: SenderCore {
    public override init(config: Config, source: @escaping () -> AudioSource) {
        super.init(config: config, source: source)
        controlsAvailable = { false }
        remoteControlEnabled = { false }
    }

    public override func makeAdvertiser(txtValues: [String: String], queue: DispatchQueue) -> AnyObject? {
        AvahiAdvertiser(name: config.macName, port: config.port, txtValues: txtValues)
    }
}

/// Builds and runs the sender for a resolved config.
public final class LinuxRuntime {
    public let config: LinuxConfig
    public let sender: LinuxSender
    /// Dialog pause (detector + REMOTE_CONTROL client); nil without `dialogPause.pairingCode`.
    public let dialog: DialogPauseService?
    private var control: ControlServer?

    public init(config: LinuxConfig) throws {
        self.config = config
        let fragment = config.frameSamples
        let kind = config.source
        let tone = config.gameMode ? 128 : 480
        let device = config.pulseDevice
        let service = config.dialogPause.pairingCode == nil ? nil
            : DialogPauseService(settings: config.dialogPause, selfName: config.name)
        dialog = service
        let tap = service?.captureTap
        switch kind {
        case .tone:
            sender = LinuxSender(config: config.senderConfig()) { ToneSource(blockFrames: tone) }
        case .wav(let path):
            _ = try WavSource(path: path)   // fail at start-up, not at the first subscriber
            let block = fragment
            sender = LinuxSender(config: config.senderConfig()) {
                // A fresh player each time capture starts; the file was checked above.
                let wav: AudioSource? = try? WavSource(path: path, blockFrames: block, tap: tap)
                return wav ?? ToneSource(amplitude: 0)
            }
        case .pulse:
            #if canImport(CPulseSimple)
            sender = LinuxSender(config: config.senderConfig()) {
                PulseSource(device: device, fragmentFrames: fragment, tap: tap)
            }
            #else
            _ = (fragment, device, tap)
            throw ConfigError("PulseAudio capture is only available on Linux; use --source tone here")
            #endif
        }
    }

    public func start() throws {
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
        dialog?.stop()    // asks the Mac to resume if it was paused for us
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
        let unconfigured = "error: dialog pause is not configured: set dialogPause.pairingCode (the Mac's pairing code) in the config and restart"
        switch command {
        case "on", "off":
            guard let dialog else { return unconfigured }
            dialog.setEnabled(command == "on")
            return "ok: dialog pause \(command)"
        case "toggle":
            guard let dialog else { return unconfigured }
            dialog.toggle()
            return "ok: dialog pause \(dialog.controller.isEnabled ? "on" : "off")"
        case "status", "":
            return dialog?.statusText() ?? "dialog pause: not configured"
        default:
            return "error: unknown command \"\(command)\" (on, off, toggle, status)"
        }
    }
}
