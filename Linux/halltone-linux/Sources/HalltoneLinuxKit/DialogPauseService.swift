import Foundation
import HalltoneCore
import HalltoneDialog
import HalltoneSenderCore
#if canImport(os)
import os
#endif

private let log = Logger(subsystem: Constants.logSubsystem, category: "Dialog")

/// Everything the dialog-pause feature needs, wired together: the tap the capture thread feeds
/// (or the per-application capture), the detector thread behind it, and the controller that talks
/// to the Mac.
public final class DialogPauseService {
    public let settings: DialogPauseSettings
    public let tap: DialogTap
    public let controller: DialogPauseController
    private let appCapture: AppStreamCapture?
    private let locator: MacLocator
    private let media: MediaController?
    /// Local target only: pauses the player too often → stops pausing.
    public let loopGuard: PauseLoopGuard?

    /// - Parameters:
    ///   - client: replaces the UDP client / local sender (tests).
    ///   - media: the PC's MPRIS controller, required for `target == .local`.
    public init(settings: DialogPauseSettings, selfName: String, client: RemoteSending? = nil, media: MediaController? = nil,
                detector: DialogConfig = DialogConfig()) {
        self.settings = settings
        self.media = settings.target == .local ? (media ?? MediaController()) : nil
        locator = MacLocator(setting: settings.mac, selfName: selfName)
        let tap = DialogTap(config: detector)
        self.tap = tap
        var guardRef: PauseLoopGuard?
        let sender: RemoteSending
        if let client {
            sender = client
        } else if let local = self.media {
            let g = PauseLoopGuard(LocalRemoteSender(media: local), maxPauses: settings.maxPauses, window: settings.pauseWindowSeconds)
            guardRef = g
            sender = g
        } else {
            sender = UDPRemoteClient(locator: locator, pairingCode: settings.pairingCode ?? 0, peerName: selfName)
        }
        loopGuard = guardRef
        let controller = DialogPauseController(timing: settings.timing, client: sender, enabled: settings.enabled,
                                               targetName: settings.target == .local ? "local player" : "Mac")
        self.controller = controller
        let local = self.media
        appCapture = settings.sourceApp.map { AppStreamCapture(app: $0, tap: tap, excluding: { local?.excludedStreamKeys() ?? [] }) }
        tap.onEvent = { controller.handle($0) }
        tap.onChunk = { controller.noteSpeech(msSince: $0) }
    }

    /// The tap the whole-monitor capture should copy into; nil when one application is analyzed instead.
    public var captureTap: DialogTap? { settings.sourceApp == nil ? tap : nil }

    public func start() {
        tap.start()
        controller.start()
        apply(controller.isEnabled)
        var how = settings.sourceApp.map { "application \"\($0)\"" } ?? "the whole monitor"
        how += settings.enabled ? "" : " (off until `halltone-linux dialog on`)"
        let st = settings
        let mac = st.target == .local ? "target: this PC's media player (MPRIS)" : "Mac \(st.mac ?? "auto-discovered")"
        log.notice("dialog pause configured: analyzing \(how, privacy: .public); minDialogMs \(st.minDialogMs), resumeDelayMs \(st.resumeDelayMs), \(mac, privacy: .public)")
    }

    public func stop() {
        tap.stop()
        appCapture?.stop()
        controller.stop()
    }

    public func setEnabled(_ on: Bool) {
        if on, !controller.isEnabled { loopGuard?.reset() }    // turning it back on clears a tripped guard
        controller.setEnabled(on)
        apply(on)
    }

    public func toggle() { setEnabled(!controller.isEnabled) }

    private func apply(_ on: Bool) {
        tap.setEnabled(on)
        if on { appCapture?.start() } else { appCapture?.stop() }
    }

    public func statusText() -> String {
        var s = controller.statusText()
        if let media {
            let eligible = media.eligiblePlayers()
            let names = eligible.map { "\($0.shortName) (\($0.status.rawValue.lowercased()))" }.joined(separator: ", ")
            s += "\ntarget: local (MPRIS): \(names.isEmpty ? "no player found" : names)"
            if loopGuard?.isTripped == true { s += "\nLOOP GUARD TRIPPED: not pausing (too many pauses in \(Int(settings.pauseWindowSeconds)) s); `dialog off` then `dialog on` clears it" }
            if appCapture?.refusedBecausePlayer == true { s += "\nNOT ANALYZING: sourceApp is the controlled player's own stream" }
        } else {
            s += "\nMac: \(locator.current ?? settings.mac ?? "not resolved yet")"
        }
        if let app = settings.sourceApp { s += "\nanalyzing: application \"\(app)\"" } else { s += "\nanalyzing: the whole monitor" }
        s += "\nminDialogMs \(settings.minDialogMs), resumeDelayMs \(settings.resumeDelayMs)"
        return s
    }
}
