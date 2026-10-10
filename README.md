# Halltone — Mac → iPhone LAN audio relay

Streams the Mac's system audio over Wi‑Fi to an iPhone, which plays it to whatever it is
connected to (AirPods). Keep YouTube running on the Mac, walk around the house with the phone.

```
Mac: process tap → ring → Opus/PCM → UDP ──LAN──▶ iPhone: jitter buffer → decode/PLC → AVAudioEngine → AirPods
```

The Mac **advertises and listens** (`_halltone._udp`, port 47800); the phone **browses and subscribes**.
The Mac only captures audio while a subscriber is alive.

## Layout

| Path | What |
|---|---|
| `Packages/HalltoneCore` | SwiftPM package shared by both apps and the CLI: `HalltoneCore` (wire format, codecs, jitter buffer, ring), `HalltoneSender` (macOS capture + UDP listener), `HalltoneReceiver` (UDP subscriber, decode pump, AVAudioEngine playback), vendored libopus (`COpus`). |
| `HalltoneMac` | macOS menu bar app (SwiftUI `MenuBarExtra`). |
| `HalltonePhone` | iOS app. |
| `Tools/halltone-cli` | macOS test tool: capture to WAV, loopback sender/receiver, impairment simulation, latency report. |
| `project.yml` | XcodeGen spec → `xcodegen generate` → `Halltone.xcodeproj`. |

## Build

Requirements: macOS 14.2+ (process taps), Xcode 16+, XcodeGen (`brew install xcodegen`).

```bash
xcodegen generate
open Halltone.xcodeproj      # schemes: HalltoneMac, HalltonePhone
```

Signing uses the Apple Development team in `project.yml` (`DEVELOPMENT_TEAM`). A free Apple ID
works for local builds (re-sign every 7 days).

Without Xcode's IDE, the Mac app and CLI also build with SwiftPM:

```bash
HalltoneMac/make-bundle.sh --run        # builds and launches HalltoneMac/.build/Halltone.app
cd Tools/halltone-cli && swift build -c release
scripts/test-core.sh                   # unit tests for HalltoneCore
```

The iPhone app needs Xcode (`xcodebuild -scheme HalltonePhone -destination 'generic/platform=iOS'`
or Run from the IDE with the phone selected).

## Setup notes

1. **AirPods automatic switching will fight this.** If the AirPods are paired to both the Mac and
   the iPhone they may jump back to the Mac when it plays audio. On the Mac: System Settings →
   Bluetooth → AirPods ⓘ → *Connect to This Mac: "When Last Connected to This Mac"*. Do the same on
   the iPhone if needed.
2. Intended workflow: at the desk, AirPods connect directly to the Mac (no delay). When leaving,
   open Halltone on the phone and tap **Connect**, then move the AirPods to the phone
   (Control Center → AirPlay icon → AirPods).
3. Grant **System Audio Recording** on the Mac (System Settings → Privacy & Security → Screen &
   System Audio Recording) and **Local Network** on both devices. The Mac app shows a shortcut
   to the setting in its menu if capture fails. Without the permission the tap delivers silence.
4. If the phone can't see the Mac, check that both are on the same VLAN or enable mDNS in UniFi,
   or add the Mac by IP with the **+** button.
5. The Mac shows a 4‑digit **pairing code** in its menu; the phone asks for it once per Mac and
   stores it in the Keychain.
6. Lock-screen play/pause/next/previous send CONTROL messages; the Mac relays them as media keys,
   which needs the **Accessibility** permission (prompted on first use).

## Wire protocol (v1)

Big-endian, one datagram per message, ≤1200 bytes. 12-byte header: magic `0x4854`, version `1`,
type, seq (u32), session (u32). Types: SUBSCRIBE 0x01, KEEPALIVE 0x02, BYE 0x03, SUBSCRIBE_ACK 0x04,
SUBSCRIBE_NAK 0x05, AUDIO 0x10 (`samplePos u64, codec u8, len u16, payload`), CONTROL 0x20.
Codecs: 1 = PCM16 interleaved stereo (240-sample / 5 ms frames, ~1.5 Mbps); 2 = Opus 48 kHz stereo
(480-sample / 10 ms frames, 128 kbps VBR, restricted-low-delay, in-band FEC flag on).

## Receiver behavior

- Jitter buffer slotted by `samplePos`: handles reorder and duplicates; target depth starts at
  60 ms, clamped to 30–250 ms; +20 ms on underruns or bursts of late packets, −5 ms after 10 s
  without trouble. Lost frames use Opus PLC (or FEC from the next packet when present); PCM fades
  to silence. Clock drift (smoothed depth ±15 ms from target) drops or duplicates one frame with a
  crossfade, at most once per second. Session change or a >1 s jump flushes and re-primes.
- No AUDIO for 1.5 s → "Reconnecting…", SUBSCRIBE re-sent every second, audio engine kept running
  (so iOS keeps the app alive in the background). Wi‑Fi interface changes recreate the socket.
- Interruptions pause and resume; AirPods removal pauses but keeps the subscription for 60 s.

## Testing

```bash
cd Tools/halltone-cli && swift build -c release && CLI=.build/release/halltone-cli

$CLI capture --seconds 10 out.wav                 # M0: process tap → WAV (play something first)
$CLI send --source tone --codec opus --no-bonjour # loopback sender with a synthetic 440 Hz tone + 1/s click
$CLI receive 127.0.0.1:47800 --wav rx.wav --seconds 10
$CLI analyze rx.wav                               # RMS, dominant frequency, silent gaps

# Impairment (no Network Link Conditioner needed) + latency report:
$CLI send --source tone --codec opus --no-bonjour --sim-loss 0.05 --sim-jitter 40 --latency-log s.csv
$CLI receive 127.0.0.1:47800 --wav rx.wav --seconds 20 --latency-log r.csv
$CLI latency s.csv r.csv
```

The latency report measures encode → scheduled-at-sink inside one Mac (same clock). Add the
capture IO buffer (~5–10 ms) and the output device latency on top. Measured on loopback: ~55 ms
on a clean link once the target has decayed to 30 ms, ~93 ms with 5% loss and 40 ms jitter.

For the real Mac → iPhone path, the phone's status screen shows buffer depth and an estimated
latency (buffer + hand-off ring + ~20 ms output), which is the rough check the spec asks for.

## Notes for maintainers

- Both audio callbacks (the tap IOProc on the Mac and the source node render block on the phone)
  only copy to/from a lock-free ring (`CHalltone/ring_buffer.c`). Encoding and decoding happen on
  dedicated high-priority threads.
- **Opus**: libopus 1.5.2 is vendored under `Packages/HalltoneCore/Sources/COpus/opus` as a plain
  float build (no NEON/x86 intrinsics). A spike showed AudioToolbox on macOS 27 also offers Opus
  encode/decode through `AVAudioConverter` (even PLC with an empty packet) but no FEC control, and
  iOS availability wasn't verified, so libopus stays.
- Logs: `log stream --predicate 'subsystem == "com.halltone"'`.

## Status and known issues (2026-10-10)

Verified end to end on a real iPhone 15 Pro (iOS 27) with AirPods Pro: Bonjour discovery, pairing,
background playback, automatic reconnect after Mac app restarts, and AirPods moving between the
Mac and the phone without dropouts or distortion. Not yet run: the desk-to-garage walk test and
the 1-hour locked-screen test.

Lessons that shaped the design:

- **Tap start.** A tap aggregate that includes the output device blocks until that device is
  awake and something plays. The aggregate is tap-only, and a silent `SilenceKeeper` engine keeps
  a writer alive so IO starts in ~150 ms.
- **Never hold the headphones from the Mac.** The silence keeper must play to the built-in
  speakers (or another wired output), not the default device: when the default output is AirPods
  that the user moved to the phone, a Mac-side stream to them makes the two devices fight over
  the AirPods (route flapping on the phone, distorted audio).
- **Bluetooth render callbacks are large.** iOS can ask for 1024–4096 frames per callback over
  Bluetooth. The decode pump keeps at least one full callback (plus a frame) decoded ahead;
  otherwise every callback underruns and the jitter target ratchets up to 250 ms.
- **Output device changes** (AirPods moving) swap the tap underneath a running encoder, which
  pads with silence, so subscribers see no gap and `samplePos` stays continuous.
- **Headroom.** Program audio often hits full scale; the phone soft-limits above −0.9 dBFS.
- If YouTube on the Mac still plays into the AirPods while they are on the phone, enable
  "Mute Mac speakers while streaming".

Sender CPU while streaming Opus: ~3.5% (CLI) / ~3.9% (menu bar app), down from ~8% after moving to
a raw UDP socket with a preallocated datagram. Idle: ~0%.

Phone diagnostics: the app appends to `Documents/halltone.log` (state, route changes, engine
restarts, per-second buffer stats); pull it with `scripts/phone-log.sh`.

Testing tips:

- Both apps' processes are named `Halltone`; when the Simulator is running, kill the Mac app by
  path (`pkill -f Halltone.app/Contents/MacOS/Halltone`), not by name.
- Headless Simulator run: build the HalltonePhone scheme for `generic/platform=iOS Simulator`,
  `xcrun simctl install <udid> …/Halltone.app`, then
  `xcrun simctl launch <udid> com.halltone.phone -pairingCode <code> -lastMac "bonjour:<Mac name>"`
  (the `-pairingCode` launch argument stands in for the Keychain; `-lastMac` triggers
  auto-connect). `xcrun simctl io <udid> screenshot out.png` shows the status screen.
- Device install: connect the iPhone (USB or paired over Wi‑Fi), select it in Xcode and run the
  HalltonePhone scheme, or `xcodebuild -scheme HalltonePhone -destination 'platform=iOS,name=<phone>'`.
