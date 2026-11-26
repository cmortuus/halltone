#if DEBUG
import SwiftUI

/// Debug builds only (the whole file is compiled out of Release): switches for measuring and testing.
enum DebugSettings {
    static let allowSpeakerOutputKey = "allowSpeakerOutput"

    /// Treat the phone's own speaker (and other shared outputs) like headphones, so the "personal
    /// outputs only" pause doesn't fire and `halltone-cli measure` can hear the phone with a Mac mic.
    static var allowSpeakerOutput: Bool { UserDefaults.standard.bool(forKey: allowSpeakerOutputKey) }
}

/// A settings section with the debug switches, shown only in Debug builds.
struct DebugSettingsSection: View {
    @AppStorage(DebugSettings.allowSpeakerOutputKey) private var allowSpeakerOutput = false

    var body: some View {
        Section {
            Toggle("Allow speaker output (latency tests)", isOn: $allowSpeakerOutput)
        } header: {
            Text("Debug")
        } footer: {
            Text("Keeps playing through the phone's speaker, CarPlay or AirPlay instead of pausing, so halltone-cli measure can hear it. Debug builds only.")
        }
    }
}
#endif
