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

    public init(config: LinuxConfig) throws {
        self.config = config
        let fragment = config.frameSamples
        let kind = config.source
        let tone = config.gameMode ? 128 : 480
        let device = config.pulseDevice
        switch kind {
        case .tone:
            sender = LinuxSender(config: config.senderConfig()) { ToneSource(blockFrames: tone) }
        case .pulse:
            #if canImport(CPulseSimple)
            sender = LinuxSender(config: config.senderConfig()) {
                PulseSource(device: device, fragmentFrames: fragment)
            }
            #else
            _ = (fragment, device)
            throw ConfigError("PulseAudio capture is only available on Linux; use --source tone here")
            #endif
        }
    }

    public func start() throws { try sender.start() }
    public func stop() { sender.stop() }
}
