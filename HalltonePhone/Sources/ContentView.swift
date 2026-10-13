import SwiftUI
import HalltoneCore
import HalltoneReceiver

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdd = false
    @State private var newHost = ""
    @State private var newPort = "47800"
    @State private var showAcknowledgements = false
    @State private var showControlsHelp = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.allMacs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Looking for Macs running Halltone…").foregroundStyle(.secondary)
                            }
                            Text("Install Halltone for Mac and keep it running, with your iPhone on the same Wi‑Fi network. If your Mac still doesn't appear, tap + and enter its IP address.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Link("Get Halltone for Mac", destination: AppLinks.macDownload).font(.footnote)
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(model.allMacs) { mac in
                        Button { model.select(mac) } label: {
                            HStack {
                                Image(systemName: mac.kind == .bonjour ? "desktopcomputer" : "network")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mac.name)
                                    if mac.away {
                                        Text("Not on this network · reachable over a VPN")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if model.selected == mac { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            if mac.kind == .manual { Button("Remove", role: .destructive) { model.removeManual(mac) } }
                            Button("Forget code") { model.forgetPairing(mac) }.tint(.orange)
                        }
                    }
                } header: {
                    Text("Macs")
                } footer: {
                    Text("Away from home? Connect your iPhone to your home network with a VPN (for example the WireGuard VPN built into UniFi, or Tailscale) and Halltone reaches your Mac over cellular, with a bit more delay.")
                }
                Section("Status") {
                    LabeledContent("State", value: stateText)
                    if model.isActive {
                        if model.stats.onCellular {
                            LabeledContent("Network", value: "Cellular · larger buffer")
                        }
                        LabeledContent("Buffer", value: "\(model.stats.bufferMs) / \(model.stats.targetMs) ms")
                        LabeledContent("Packet loss", value: String(format: "%.1f%%", model.stats.lossPercent))
                        LabeledContent("Est. latency", value: "~\(model.stats.estimatedLatencyMs + 20) ms + Bluetooth")
                        LabeledContent("Bitrate", value: "\(model.stats.kilobitsPerSecond) kbps")
                        LabeledContent("Underruns", value: "\(model.stats.underruns)")
                    }
                }
                if model.isActive, let available = model.stats.macControlsAvailable {
                    Section("Headphone controls") {
                        if available {
                            Label("Tap your AirPods to pause or skip on your Mac", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Tapping your AirPods can't pause your Mac yet", systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                            Button("How to turn it on") { showControlsHelp = true }
                        }
                    }
                }
                Section {
                    Toggle("Keep headphones on this iPhone", isOn: $model.keepHeadphones)
                } footer: {
                    if model.isActive, model.stats.macCanHoldHeadphones == false {
                        Text("Update Halltone on your Mac to use this.")
                    } else {
                        Text("While you're listening, your Mac won't take your AirPods back when it plays something, and if moving them to this iPhone paused your video, it starts again by itself.")
                    }
                }
                Section {
                    Picker("Latency", selection: $model.latencyMode) {
                        Text("Auto").tag(LatencyMode.auto)
                        Text("Lowest").tag(LatencyMode.lowest)
                        Text("Balanced").tag(LatencyMode.balanced)
                        Text("Stable").tag(LatencyMode.stable)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Playback")
                } footer: {
                    Text(latencyFooter)
                }
                Section {
                    Toggle("Auto-connect on launch", isOn: $model.autoConnect)
                }
                Section("About") {
                    LabeledContent("Version", value: AppLinks.version)
                    Link("Help & Mac app", destination: AppLinks.home)
                    ShareLink(item: model.diagnosticsURL) {
                        Label("Share diagnostics log", systemImage: "doc.text.magnifyingglass")
                    }
                    Button("Acknowledgements") { showAcknowledgements = true }
                }
            }
            .navigationTitle("Halltone")
            .toolbar {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if model.paused {
                        Button("Resume") { model.resume() }.buttonStyle(.bordered)
                    }
                    Button(action: model.toggle) {
                        Text(model.isActive ? "Disconnect" : "Connect")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isActive ? .red : .accentColor)
                    .disabled(!model.isActive && model.selected == nil)
                }
                .padding()
                .background(.bar)
            }
            .sheet(isPresented: $showAdd) { addSheet }
            .sheet(isPresented: $showControlsHelp) { ControlsHelpView(macName: model.stats.macName) }
            .alert("Pause isn't set up yet", isPresented: Binding(get: { model.showControlsHelpBanner }, set: { if !$0 { model.dismissControlsHelpBanner() } })) {
                Button("Show me how") { model.dismissControlsHelpBanner(); showControlsHelp = true }
                Button("Later", role: .cancel) { model.dismissControlsHelpBanner() }
            } message: {
                Text("Your Mac needs one setting before your AirPods can pause or skip it.")
            }
            .sheet(isPresented: $showAcknowledgements) {
                NavigationStack {
                    ScrollView {
                        Text(Acknowledgements.text)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .padding()
                    }
                    .navigationTitle("Acknowledgements")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { showAcknowledgements = false } }
                }
            }
            .alert("Pairing code", isPresented: Binding(get: { model.pairingPrompt != nil }, set: { if !$0 { model.pairingPrompt = nil } })) {
                TextField("1234", text: $model.pairingInput).keyboardType(.numberPad)
                Button("Connect") { model.submitPairingCode() }
                Button("Cancel", role: .cancel) { model.pairingPrompt = nil }
            } message: {
                Text(model.pairingError ?? "Enter the code shown in the Halltone menu on \(model.pairingPrompt?.name ?? "your Mac").")
            }
            .alert("Error", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
                Button("OK") { model.errorText = nil }
            } message: { Text(model.errorText ?? "") }
        }
    }

    private var latencyFooter: String {
        switch model.latencyMode {
        case .auto:
            let now: String
            switch (model.isActive, model.stats.macUserActive) {
            case (true, true?): now = " Right now: you're at your Mac, so it's close to real time."
            case (true, false?): now = " Right now: away from your Mac, so extra buffer for smooth audio."
            default: now = ""
            }
            return "Smooth, dropout-free audio while you're away from your Mac; close to real time when you're using it." + now
        case .lowest: return "Closest to real time, for watching video on the Mac. Uses only as much delay as your Wi‑Fi needs to play smoothly."
        case .balanced: return "Adapts to your Wi‑Fi: no more delay than it needs to avoid dropouts."
        case .stable: return "About a third of a second behind, but rides out moving between Wi‑Fi access points and weak spots. Best for music and podcasts while you move around."
        }
    }

    private var stateText: String {
        switch model.state {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .subscribed(let mac): return model.paused ? "Paused (\(mac))" : "Connected to \(mac)"
        case .reconnecting: return "Reconnecting…"
        case .rejected(let r): return "Rejected: \(r)"
        case .failed(let r): return "Failed: \(r)"
        }
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                TextField("IP address or hostname", text: $newHost)
                    .keyboardType(.decimalPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", text: $newPort).keyboardType(.numberPad)
            }
            .navigationTitle("Add Mac manually")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showAdd = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        model.addManual(host: newHost, port: UInt16(newPort) ?? Constants.defaultPort)
                        showAdd = false
                    }.disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
