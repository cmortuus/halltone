import AppKit
import ApplicationServices
import HalltoneCore

/// Posts the media keys (play/pause, next, previous) as system-defined HID events, exactly as the
/// keyboard would. Needs the Accessibility permission; the first use prompts for it.
enum MediaKeys {
    private static let play: Int32 = 16      // NX_KEYTYPE_PLAY
    private static let next: Int32 = 19      // NX_KEYTYPE_FAST
    private static let previous: Int32 = 20  // NX_KEYTYPE_REWIND

    static func send(_ cmd: ControlCommand) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { return }
        let key: Int32
        switch cmd {
        case .playPause: key = play
        case .next: key = next
        case .previous: key = previous
        }
        post(key, down: true)
        post(key, down: false)
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
