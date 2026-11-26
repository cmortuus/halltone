import Foundation
import Network
import HalltoneCore
import HalltoneReceiver

/// `receive --multi HOST[:PORT]...`: listen to several senders at once through the phone's own
/// `SourceManager` and mix bus, to speakers or one WAV. This is how the multi-source path is checked
/// without a phone: two `send --source tone --freq ...` instances, then `analyze --tones`.
func runReceiveMulti(targets: [String], codes: [UInt32], volumes: [Float], name: String, wav: URL?,
                     seconds: Double?, mode: LatencyMode?, muteIndexes: Set<Int>) throws {
    let output = try ReceiveOutput(wav: wav)
    let manager = SourceManager(bus: output.bus, store: MemorySettingsStore())
    let ids = targets.map { "cli:\($0)" }
    func tag(_ s: Source) -> String { "[recv \(s.name)]" }
    manager.onState = { s, st in print("\(tag(s)) state: \(st)"); fflush(stdout) }
    manager.onStats = { s, st in
        guard st.state.isActive else { return }
        print("\(tag(s)) \(st.packetsPerSecond) pkt/s \(st.kilobitsPerSecond) kbps buffer \(st.bufferMs)/\(st.targetMs) ms loss \(st.lossPercent)% underruns \(st.underruns) frame \(st.frameMs) ms mode \(s.effectiveMode.rawValue)")
        fflush(stdout)
    }
    for (i, target) in targets.enumerated() {
        let code = codes.indices.contains(i) ? codes[i] : (codes.first ?? 0)
        guard manager.connect(id: ids[i], name: target, endpoint: parseEndpoint(target), pairingCode: code, deviceName: name) != nil else {
            throw NSError(domain: "halltone-cli", code: 1, userInfo: [NSLocalizedDescriptionKey: "too many sources (max \(MixBus.maxChannels))"])
        }
        if volumes.indices.contains(i) { manager.setVolume(volumes[i], for: ids[i]) }
        if muteIndexes.contains(i) { manager.setMuted(true, for: ids[i]) }
        if let mode { manager.setLatency(mode, for: ids[i]) }
    }
    if let seconds {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    } else {
        signal(SIGINT) { _ in exit(0) }
        RunLoop.main.run()
    }
    manager.disconnectAll()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    output.finish()
}
