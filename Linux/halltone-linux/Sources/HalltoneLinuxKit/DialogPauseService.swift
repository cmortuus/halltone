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

    /// - Parameter client: replaces the UDP client (tests).
    public init(settings: DialogPauseSettings, selfName: String, client: RemoteSending? = nil, detector: DialogConfig = DialogConfig()) {
        self.settings = settings
        locator = MacLocator(setting: settings.mac, selfName: selfName)
        let tap = DialogTap(config: detector)
        self.tap = tap
        let sender = client ?? UDPRemoteClient(locator: locator, pairingCode: settings.pairingCode ?? 0, peerName: selfName)
        let controller = DialogPauseController(timing: settings.timing, client: sender, enabled: settings.enabled)
        self.controller = controller
        appCapture = settings.sourceApp.map { AppStreamCapture(app: $0, tap: tap) }
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
        let mac = st.mac ?? "auto-discovered"
        log.notice("dialog pause configured: analyzing \(how, privacy: .public); minDialogMs \(st.minDialogMs), resumeDelayMs \(st.resumeDelayMs), Mac \(mac, privacy: .public)")
    }

    public func stop() {
        tap.stop()
        appCapture?.stop()
        controller.stop()
    }

    public func setEnabled(_ on: Bool) {
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
        s += "\nMac: \(locator.current ?? settings.mac ?? "not resolved yet")"
        if let app = settings.sourceApp { s += "\nanalyzing: application \"\(app)\"" } else { s += "\nanalyzing: the whole monitor" }
        s += "\nminDialogMs \(settings.minDialogMs), resumeDelayMs \(settings.resumeDelayMs)"
        return s
    }
}
