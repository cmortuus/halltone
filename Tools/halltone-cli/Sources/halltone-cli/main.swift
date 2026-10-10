import Foundation
import HalltoneCore

let usage = """
halltone-cli — Halltone test tool

  capture --seconds N [--mute] [--with-output-device] [--no-autostart] out.wav
                                           capture system audio with the process tap
  tone --seconds N --freq HZ out.wav       write a test sine (16-bit stereo 48k)
  analyze in.wav                           print RMS/peak and dominant frequency
  send [--port 47800] [--source tap|tone] [--codec pcm|opus] [--mute] [--code N]
       [--no-bonjour] [--seconds N] [--sim-loss 0.05] [--sim-jitter 40]
       [--latency-log send.csv] [--swap-every N] [--sim-burst MS [--sim-burst-every MS]]
                                           run the sender (capture on demand)
  receive HOST[:PORT] [--code N] [--name X] [--wav out.wav] [--seconds N]
       [--latency-log recv.csv]            subscribe; play (default) or write decoded audio to a WAV
  latency send.csv recv.csv                report loopback latency from the two logs
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(2) }
args.removeFirst()

/// Pulls `--name value` (or `--flag`) options out of `args`, leaving positionals.
func option(_ name: String, default def: String? = nil) -> String? {
    guard let i = args.firstIndex(of: name) else { return def }
    guard i + 1 < args.count else { args.remove(at: i); return def }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

do {
    switch command {
    case "capture":
        let seconds = Double(option("--seconds", default: "10")!) ?? 10
        let mute = flag("--mute")
        let tapOnly = !flag("--with-output-device")
        let noAutoStart = flag("--no-autostart")
        guard let out = args.first else { print(usage); exit(2) }
        try runCapture(seconds: seconds, mute: mute, tapOnly: tapOnly, autoStart: !noAutoStart, output: URL(fileURLWithPath: out))
    case "tone":
        let seconds = Double(option("--seconds", default: "5")!) ?? 5
        let freq = Double(option("--freq", default: "440")!) ?? 440
        guard let out = args.first else { print(usage); exit(2) }
        try writeTone(seconds: seconds, frequency: freq, output: URL(fileURLWithPath: out))
    case "analyze":
        guard let path = args.first else { print(usage); exit(2) }
        try analyze(URL(fileURLWithPath: path))
    case "send":
        let port = UInt16(option("--port", default: "47800")!) ?? 47800
        let source = option("--source", default: "tap")!
        let codec: CodecID = option("--codec", default: "pcm") == "opus" ? .opus : .pcm16
        let mute = flag("--mute")
        let code = option("--code").flatMap { UInt32($0) }
        let noBonjour = flag("--no-bonjour")
        let seconds = option("--seconds").flatMap { Double($0) }
        let simLoss = Double(option("--sim-loss", default: "0")!) ?? 0
        let simJitter = Double(option("--sim-jitter", default: "0")!) ?? 0
        let latencyLog = option("--latency-log").map { URL(fileURLWithPath: $0) }
        let swapEvery = option("--swap-every").flatMap { Double($0) }
        let burst = Double(option("--sim-burst", default: "0")!) ?? 0
        let burstEvery = Double(option("--sim-burst-every", default: "2000")!) ?? 2000
        try runSend(port: port, sourceKind: source, codec: codec, mute: mute, pairingCode: code, advertise: !noBonjour,
                    seconds: seconds, simLoss: simLoss, simJitterMs: simJitter, latencyLog: latencyLog, swapEvery: swapEvery,
                    burstMs: burst, burstEveryMs: burstEvery)
    case "receive":
        let code = UInt32(option("--code", default: "0")!) ?? 0
        let name = option("--name", default: "halltone-cli")!
        let wav = option("--wav").map { URL(fileURLWithPath: $0) }
        let seconds = option("--seconds").flatMap { Double($0) }
        let latencyLog = option("--latency-log").map { URL(fileURLWithPath: $0) }
        guard let target = args.first else { print(usage); exit(2) }
        try runReceive(target: target, pairingCode: code, name: name, wav: wav, seconds: seconds, latencyLog: latencyLog)
    case "latency":
        guard args.count == 2 else { print(usage); exit(2) }
        try reportLatency(send: URL(fileURLWithPath: args[0]), receive: URL(fileURLWithPath: args[1]))
    default:
        print(usage); exit(2)
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
