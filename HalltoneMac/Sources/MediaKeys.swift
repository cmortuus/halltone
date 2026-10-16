import AppKit
import ApplicationServices
import HalltoneCore

/// Posts the media keys (play/pause, next, previous) as system-defined HID events, exactly as the
/// keyboard would. Needs the Accessibility permission, which the user grants through
/// `requestPermission()` (from the "Headphone controls" row in the menu) — never as a surprise
/// prompt when a headphone press arrives while they are away from the Mac.
enum MediaKeys {
    private static let play: Int32 = 16      // NX_KEYTYPE_PLAY
    private static let next: Int32 = 19      // NX_KEYTYPE_FAST
    private static let previous: Int32 = 20  // NX_KEYTYPE_REWIND

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Explains what is about to happen, adds Halltone to the Accessibility list and opens it.
    static func requestPermission() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Pause and skip from your headphones"
        alert.informativeText = """
        When you tap your AirPods (or use the lock screen) on your iPhone, Halltone presses this \
        Mac's play/pause key for you, so YouTube or Music pauses here.

        macOS will say Halltone "would like to control this Mac". That's this feature. Click \
        Open System Settings, then switch Halltone on. You may be asked for your Mac's password.
        """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Shows the system dialog (its "Open System Settings" button goes to the right page) and
        // adds Halltone to the Accessibility list.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Returns false (and posts nothing) when the Accessibility permission is missing.
    @discardableResult
    static func send(_ cmd: ControlCommand) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let key: Int32
        switch cmd {
        case .playPause, .play, .pause: key = play
        case .next: key = next
        case .previous: key = previous
        case .holdHeadphonesOn, .holdHeadphonesOff, .listening, .notListening: return false
        }
        post(key, down: true)
        post(key, down: false)
        return true
    }

    private static func post(_ key: Int32, down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
        let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
        guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             subtype: 8, data1: data1, data2: -1) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
