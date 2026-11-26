# HalltoneDialog

A real-time **dialog detector**: given 48 kHz stereo game audio (music, effects and speech mixed),
it reports when characters start and stop talking. `halltone-linux` uses it to pause a video on
the Mac during in-game dialog (see the main README). This package is only the detector and an evaluation tool.

No Apple frameworks: it builds and tests on macOS and Linux (`swift build && swift test`).

```swift
import HalltoneDialog

let detector = DialogDetector(config: DialogConfig())          // allocates here, nowhere else
// from the audio thread, 48 kHz interleaved stereo Float32:
detector.process(samples, frames: n) { event in
    switch event {
    case .started(let time, let detectedAt): …   // dialog began at `time`, known at `detectedAt`
    case .ended(let time, let detectedAt): …
    }
}
// detector.msSinceSpeech: while active, ms since the last sustained speech frame
// or: let events = detector.process(samples, frames: n)      // [DialogEvent]; allocates only when an event occurred
```

## Pipeline (10 ms frames)

1. **Center extraction.** Dialog is usually center-panned. `mid = (L+R)/2`, `side = (L−R)/2`; mid's
   power is reduced by `centerSideScale × side power` (a power-domain "mid minus a scaled side
   estimate", applied as a smoothed gain on mid). Wide music/effects (lots of side) are suppressed; a
   centered voice (no side) passes untouched.
2. **16 kHz + libfvad** (WebRTC VAD, mode 3) on the extracted center, after a 48-tap 3:1 anti-aliased decimator.
3. **Gates** on every frame: minimum level (−45 dBFS RMS of the center), speech-band energy ratio
   (300–3400 Hz vs. full band, smoothed), and a modulation gate (the speech-band level must move
   ≥ 8 dB within the 400 ms window — speech is syllabic; tones, hiss and pads are not).
4. **Hysteresis:** `started` after 250 ms of speech frames within 400 ms; `ended` after 1.2 s with none. While active, a speech frame only resets that countdown if ≥ 50 ms of speech was seen in the last 200 ms, so isolated false-positive frames (beat-driven music) cannot hold a finished line open.

All thresholds are in `DialogConfig`. Latency is therefore ≈ 0.25 s to start and exactly
`endSilenceMs` (1.2 s) to end; each event carries both the estimated onset/offset (`time`) and when
it became known (`detectedAt`). CPU is ≈ 0.06 % of one core on an Apple-silicon Mac (release).

**Working range.** Center extraction over-subtracts side power, so dialog should be at least about as
loud as the music around it: measured with level-matched (RMS) TTS over loud wide music, both `say`
and `espeak-ng` are found with ≥ 98 % frame recall at +3 dB over the music, ~92–96 % at 0 dB (line ends
get held open by music), and increasingly lost below that. Game mixes normally duck music under dialog.

## Evaluation tool

```bash
swift run -c release halltone-dialog-eval in.wav [--labels labels.txt]
swift run -c release halltone-dialog-eval --make-demo demo.wav --labels-out demo.txt   # speech via say/espeak-ng over music-like noise
```

Prints the event timeline and CPU cost; with Audacity-format labels (`start<TAB>end<TAB>label`) also
frame precision/recall and median start/end latency. Any WAV rate/channel count is accepted
(resampled to 48 kHz stereo). Thresholds can be overridden with `--side-scale`, `--band-ratio`,
`--min-level`, `--vad-mode`, `--start-ms`, `--window-ms`, `--end-ms`. Because the detector holds the
state through short pauses, labels closer than the hold-off can be merged with `--merge-gap`.

## Tests

Speech is generated at test time (`say` on macOS, `espeak-ng` on Linux) and the speech tests skip when
neither exists. No audio is committed. Speech levels are set by RMS relative to the music, not by peak
(the two engines differ ~7 dB in crest factor). `HALLTONE_TTS=/path/to/espeak-ng swift test` forces an
engine, e.g. to reproduce Linux results on a Mac; the eval tool's `--make-demo` honors it too.

## Vendored code

`Sources/CFVAD` is [libfvad](https://github.com/dpirch/libfvad) (BSD-3-Clause), pinned and described
in `Sources/CFVAD/VENDORED.md`.
