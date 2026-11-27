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
                        SourceRow(mac: mac)
                    }
                    .onDelete { offsets in
                        let macs = model.allMacs
                        offsets.map { macs[$0] }.forEach { model.delete($0) }
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Turn on one source, or several to hear them mixed: each gets its own volume, mute and latency below. Away from home? Run Tailscale on your iPhone and your Mac (or connect to your home network with a VPN, such as the one built into UniFi) and Halltone reaches your Mac over cellular, with a bit more delay. Open Halltone once at home first so it learns your Mac's address.")
                }
                if model.sources.isEmpty {
                    Section("Status") {
                        LabeledContent("State", value: "Not connected")
                    }
                }
                ForEach(model.sources) { src in
                    SourceSection(source: src, showName: model.sources.count > 1)
                }
                headphoneControlsSection
                Section {
                    Toggle("Keep headphones on this iPhone", isOn: $model.keepHeadphones)
                } footer: {
                    if model.isActive, model.sources.allSatisfy({ $0.stats.macCanHoldHeadphones == false }) {
                        Text("Update Halltone on your Mac to use this.")
                    } else {
                        Text("While you're listening, your Mac won't take your AirPods back when it plays something, and if moving them to this iPhone paused your video, it starts again by itself.")
                    }
                }
                Section {
                    Toggle("Auto-connect on launch", isOn: $model.autoConnect)
                }
                #if DEBUG
                DebugSettingsSection()
                #endif
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
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if model.paused {
                        Button("Resume") { model.userResume() }.buttonStyle(.bordered)
                    }
                    Button(action: model.toggle) {
                        Text(model.isActive ? "Disconnect" : "Connect")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isActive ? .red : .accentColor)
                    .disabled(!model.isActive && !model.canConnect)
                }
                .padding()
                .background(.bar)
            }
            .sheet(isPresented: $showAdd) { addSheet }
            .sheet(isPresented: $showControlsHelp) { ControlsHelpView(macName: model.controlsHelpName) }
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
                Button("Cancel", role: .cancel) { model.cancelPairing() }
            } message: {
                Text(model.pairingError ?? "Enter the code shown in the Halltone menu on \(model.pairingPrompt?.name ?? "your Mac").")
            }
            .alert("Error", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
                Button("OK") { model.errorText = nil }
            } message: { Text(model.errorText ?? "") }
        }
    }

    @ViewBuilder private var headphoneControlsSection: some View {
        let reporting = model.sources.filter { $0.stats.macControlsAvailable != nil }
        if model.isActive, !reporting.isEmpty {
            Section("Headphone controls") {
                if model.sources.count == 1, let available = reporting.first?.stats.macControlsAvailable {
                    controlsRow(available: available, name: nil)
                } else {
                    ForEach(reporting) { src in
                        controlsRow(available: src.stats.macControlsAvailable == true, name: src.name)
                    }
                    if let media = model.sources.first(where: { $0.isMediaSource }) {
                        Label("Lock screen and headphone buttons control \(media.name)", systemImage: "airpodspro")
                            .font(.footnote)
                    } else {
                        Label("None of these sources can be paused from the lock screen", systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if reporting.contains(where: { $0.stats.macControlsAvailable == false }) {
                    Button("How to turn it on") { showControlsHelp = true }
                }
            }
        }
    }

    @ViewBuilder private func controlsRow(available: Bool, name: String?) -> some View {
        if available {
            Label(name.map { "\($0): tap your AirPods to pause or skip" } ?? "Tap your AirPods to pause or skip on your Mac",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label(name.map { "\($0): tapping your AirPods can't pause it yet" } ?? "Tapping your AirPods can't pause your Mac yet",
                  systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
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

/// One discovered or remembered sender with its on/off switch. Turning on several connects to all
/// of them; the first one on starts playback, the rest are mixed in.
private struct SourceRow: View {
    @EnvironmentObject var model: AppModel
    let mac: MacEntry

    var body: some View {
        HStack {
            Image(systemName: mac.kind == .bonjour ? "desktopcomputer" : "network")
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name)
                if mac.away {
                    Text(mac.viaTailscale ? "Not on this network · over Tailscale" : "Not on this network · reachable over a VPN")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle(mac.name, isOn: Binding(
                get: { model.isOn(mac.id) },
                set: { on in if on { model.connect(mac) } else { model.turnOff(mac.id) } }))
                .labelsHidden()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", role: .destructive) { model.delete(mac) }
            Button("Forget code") { model.forgetPairing(mac) }.tint(.orange)
        }
        .contextMenu {
            Button("Forget pairing code") { model.forgetPairing(mac) }
            Button("Delete", role: .destructive) { model.delete(mac) }
        }
    }
}

/// Status of one connected source: state, its own volume, mute and latency mode, and the buffer
/// numbers that used to be the whole Status section.
private struct SourceSection: View {
    @EnvironmentObject var model: AppModel
    let source: SourceStatus
    /// More than one source: the header names it (with one it is just "Status").
    let showName: Bool

    private var stats: Receiver.Stats { source.stats }

    var body: some View {
        Section {
            LabeledContent("State", value: stateText)
            if stats.state.isActive {
                volumeRow
                Picker("Latency", selection: Binding(get: { source.config.latency },
                                                     set: { model.setLatency($0, for: source.id) })) {
                    Text("Default (\(defaultMode.title))").tag(LatencyMode?.none)
                    ForEach(LatencyMode.allCases, id: \.self) { Text($0.title).tag(LatencyMode?.some($0)) }
                }
                .pickerStyle(.menu)
                if stats.onCellular {
                    LabeledContent("Network", value: "Cellular · larger buffer")
                }
                LabeledContent("Buffer", value: "\(stats.bufferMs) / \(stats.targetMs) ms")
                LabeledContent("Packet loss", value: String(format: "%.1f%%", stats.lossPercent))
                LabeledContent("Est. latency", value: "~\(latencyTotalMs) ms")
                LabeledContent("  Frame", value: String(format: "%.1f ms", stats.frameMs))
                LabeledContent("  Jitter buffer", value: "\(jitterBufferMs) ms")
                LabeledContent("  Hand-off ring", value: "\(stats.handoffMs) ms")
                LabeledContent("  Output", value: "\(model.outputLatencyMs) ms")
                LabeledContent("Bitrate", value: "\(stats.kilobitsPerSecond) kbps")
                LabeledContent("Underruns", value: "\(stats.underruns)")
            }
        } header: {
            Text(showName ? source.name : "Status")
        } footer: {
            if stats.state.isActive { Text(latencyFooter) }
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 12) {
            Button {
                model.setMuted(!source.config.muted, for: source.id)
            } label: {
                Image(systemName: source.config.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 28)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(source.config.muted ? "Unmute \(source.name)" : "Mute \(source.name)")
            Slider(value: Binding(get: { Double(source.config.volume) },
                                  set: { model.setVolume(Float($0), for: source.id) }), in: 0...1)
                .disabled(source.config.muted)
                .accessibilityLabel("Volume of \(source.name)")
        }
    }

    private var defaultMode: LatencyMode { LatencyMode.resolve(choice: nil, frameSamples: stats.frameSamples) }

    private var latencyFooter: String {
        let mode = source.effectiveMode
        let isDefault = source.config.latency == nil
        switch mode {
        case .auto:
            let now: String
            if stats.atMac { now = " Right now: you're at your Mac, so it's close to real time." }
            else { now = " Right now: away from your Mac, so extra buffer for smooth audio." }
            return "Smooth, dropout-free audio while you're away from your Mac; close to real time when you're using it." + now
        case .lowest: return "Closest to real time, for watching video on the Mac. Uses only as much delay as your Wi‑Fi needs to play smoothly."
        case .balanced: return "Adapts to your Wi‑Fi: no more delay than it needs to avoid dropouts."
        case .stable: return "About a third of a second behind, but rides out moving between Wi‑Fi access points and weak spots. Best for music and podcasts while you move around."
        case .game: return (isDefault ? "Used because this sender sends 2.5 ms frames (its Game mode). " : "")
            + "For playing games with this iPhone on the desk next to your computer: about 40–55 ms before your headphones. Keep this app open (the screen stays on), and use wired or USB‑C headphones: Bluetooth headphones add about 150–250 ms of their own. Rare short audio fades on weak Wi‑Fi instead of extra delay."
        }
    }

    /// Whole-path estimate from the Mac's encode to the headphones (not counting the headphones'
    /// own delay, or the Mac's capture buffer): frame + jitter buffer + hand-off ring + output.
    private var latencyTotalMs: Int {
        Int((stats.frameMs + Double(stats.bufferMs + model.outputLatencyMs)).rounded())
    }

    /// `bufferMs` is the whole playout depth (jitter buffer plus the decoded hand-off ring).
    private var jitterBufferMs: Int { max(0, stats.bufferMs - stats.handoffMs) }

    private var stateText: String {
        switch stats.state {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .subscribed(let mac): return model.paused ? "Paused (\(mac))" : "Connected to \(mac)"
        case .reconnecting: return "Reconnecting…"
        case .rejected(let r): return "Rejected: \(r)"
        case .failed(let r): return "Failed: \(r)"
        }
    }
}

extension LatencyMode {
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .lowest: return "Lowest"
        case .balanced: return "Balanced"
        case .stable: return "Stable"
        case .game: return "Game"
        }
    }
}
