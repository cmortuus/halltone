import SwiftUI

/// Plain-language steps for turning on headphone controls on the Mac.
struct ControlsHelpView: View {
    let macName: String
    @Environment(\.dismiss) private var dismiss

    private var mac: String { macName.isEmpty ? "your Mac" : macName }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Halltone can pause, play and skip whatever is playing on \(mac) when you tap your AirPods or use the lock screen. \(mac) needs one setting first. You only do this once.")
                        .font(.callout)
                }
                Section("On \(mac)") {
                    step(1, "Click the Halltone ear icon in the menu bar, at the top right of the screen.", icon: "ear")
                    step(2, "Next to Headphone controls, click Turn On…", icon: "airpods")
                    step(3, "Click Continue, then Open System Settings.", icon: "gearshape")
                    step(4, "Find Halltone in the list and switch it on. Enter the Mac's password if asked.", icon: "switch.2")
                }
                Section {
                    Text("This screen updates by itself once it's on. Then just tap your AirPods.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Headphone controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func step(_ n: Int, _ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                Image(systemName: icon).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
