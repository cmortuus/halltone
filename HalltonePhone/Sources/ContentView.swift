import SwiftUI
import HalltoneCore
import HalltoneReceiver

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdd = false
    @State private var newHost = ""
    @State private var newPort = "47800"

    var body: some View {
        NavigationStack {
            List {
                Section("Macs") {
                    if model.allMacs.isEmpty {
                        Text("Looking for Macs running Halltone…").foregroundStyle(.secondary)
                    }
                    ForEach(model.allMacs) { mac in
                        Button { model.select(mac) } label: {
                            HStack {
                                Image(systemName: mac.kind == .bonjour ? "desktopcomputer" : "network")
                                Text(mac.name)
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
                }
                Section("Status") {
                    LabeledContent("State", value: stateText)
                    if model.isActive {
                        LabeledContent("Buffer", value: "\(model.stats.bufferMs) / \(model.stats.targetMs) ms")
                        LabeledContent("Packet loss", value: String(format: "%.1f%%", model.stats.lossPercent))
                        LabeledContent("Est. latency", value: "~\(model.stats.estimatedLatencyMs + 20) ms + Bluetooth")
                        LabeledContent("Bitrate", value: "\(model.stats.kilobitsPerSecond) kbps")
                        LabeledContent("Underruns", value: "\(model.stats.underruns)")
                    }
                }
                Section {
                    Toggle("Auto-connect on launch", isOn: $model.autoConnect)
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
