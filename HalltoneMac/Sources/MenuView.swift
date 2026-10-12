import SwiftUI
import HalltoneCore

struct MenuView: View {
    @EnvironmentObject var model: SenderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let err = model.startError {
                    Label("Not listening: \(err)", systemImage: "exclamationmark.triangle")
                } else if model.stats.subscribers.isEmpty {
                    Label("Idle · listening on port \(String(model.port))", systemImage: "ear")
                } else {
                    Label("Streaming to \(model.stats.subscribers.map(\.name).joined(separator: ", "))", systemImage: "ear.fill")
                    Text("\(model.liveStats.kilobitsPerSecond) kbps · \(model.liveStats.packetsPerSecond) pkt/s")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.liveStats.subscribers) { s in
                        Text("\(s.name): buffer \(s.bufferMs) ms, loss \(Double(s.lossPermille) / 10, specifier: "%.1f")%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let capErr = model.stats.captureError {
                    Text("Capture failed: \(capErr)").font(.caption).foregroundStyle(.red)
                    Button("Open System Audio Recording settings…") { model.openAudioCapturePrivacySettings() }
                }
            }
            Divider()
            HStack(alignment: .top) {
                Image(systemName: "airpods")
                    .foregroundStyle(model.controlsEnabled ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Headphone controls: \(model.controlsEnabled ? "On" : "Off")")
                    Text(model.controlsEnabled
                         ? "Tap your AirPods to pause or skip here."
                         : "Lets a tap on your AirPods pause or skip on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.controlsEnabled {
                    Button("Turn On…") { model.enableHeadphoneControls() }
                }
            }
            if model.holdingHeadphones {
                Label("Keeping headphones on iPhone", systemImage: "lock.iphone")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("A listening iPhone asked this Mac not to take its headphones back. Turn it off in Halltone on the iPhone.")
            }
            Toggle("Mute Mac speakers while streaming", isOn: $model.muteWhileStreaming)
            Picker("Codec", selection: $model.codec) {
                Text("Opus (128 kbps)").tag(CodecID.opus)
                Text("PCM 16-bit (1.5 Mbps)").tag(CodecID.pcm16)
            }
            Toggle("Launch at login", isOn: $model.launchAtLogin)
            Divider()
            HStack {
                Text("Pairing code: ").foregroundStyle(.secondary) + Text(String(model.pairingCode)).font(.title3.monospacedDigit().bold())
                Spacer()
                Button("New code") { model.regeneratePairingCode() }
            }
            Divider()
            HStack {
                Button("About & Acknowledgements…") { AboutPanel.show() }
                Spacer()
                Button("Quit Halltone") { model.quit() }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.panelVisible = true }
        .onDisappear { model.panelVisible = false }
    }
}
