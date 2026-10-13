import CoreGraphics
import Foundation

/// Is someone using this Mac? Used by the phone's Auto latency mode.
///
/// Yes after any keyboard, mouse or trackpad input in the last `idleLimit`; no as soon as the
/// screen locks or the display sleeps. Watching a video without touching anything counts as
/// present for `idleLimit`, then the phone eases into its larger buffer.
enum UserPresence {
    static let idleLimit: TimeInterval = 180

    /// Input within this long: someone is definitely at the Mac right now.
    static let recentInputLimit: TimeInterval = 20

    static var inputRecent: Bool { idleSeconds < recentInputLimit && !CGDisplayIsAsleepMain }

    private static var CGDisplayIsAsleepMain: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    private static var idleSeconds: TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
    }

    static var isAtMac: Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return false }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true { return false }
        // kCGAnyInputEventType: seconds since the last input event of any kind. No permission needed.
        guard let any = CGEventType(rawValue: ~0) else { return false }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any) < idleLimit
    }
}
