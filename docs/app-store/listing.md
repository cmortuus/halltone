# App Store listing — Halltone (iPhone)

Everything App Store Connect asks for, ready to paste. Character limits in brackets.

## App information
- **Name** [30]: `Halltone`
- **Subtitle** [30]: `Your Mac's audio, anywhere` (26)
- **Bundle ID**: `com.halltone.phone`
- **Primary category**: Music · **Secondary**: Utilities
- **Content rights**: does not contain, show, or access third-party content
- **Age rating**: answer "None" to every question → 4+
- **Price**: Tier 1 ($0.99 USD), all territories

## Promotional text [170]
Keep the Mac playing at your desk and take the sound with you. Halltone streams your Mac's audio to your iPhone over Wi‑Fi, so your headphones go wherever you go.

## Description [4000]
Halltone streams everything your Mac is playing to your iPhone over your home Wi‑Fi. Leave a video, playlist, or podcast queue running on the Mac, put your phone in your pocket, and keep listening on your AirPods or any headphones connected to the phone, in any room your Wi‑Fi reaches.

Bluetooth headphones drop out a few rooms away from the Mac. With Halltone they stay connected to the phone in your pocket, and the audio crosses the house over Wi‑Fi instead.

• Low latency: about a tenth of a second on a good network, plus your headphones' own delay
• Survives Wi‑Fi dead spots: reconnects by itself as soon as you're back in range
• Keeps playing with the screen locked
• High-quality Opus audio, or uncompressed 16‑bit audio if your network has room for it
• Lock‑screen and headphone controls: play/pause and skip on the Mac from your phone
• Private by design: audio stays on your local network; no accounts, no tracking, no data collection
• Pairing code so only your phones can listen

Requires the free Halltone app for Mac (macOS 14.2 or later), on the same local network as your iPhone. Get it at github.com/cmortuus/halltone.

## Keywords [100]
`stream,mac,audio,wifi,airpods,headphones,speaker,relay,listen,remote,sound,computer,desktop,cast`
(97)

## URLs
- **Support URL**: https://github.com/cmortuus/halltone/issues
- **Marketing URL**: https://github.com/cmortuus/halltone
- **Privacy Policy URL**: https://github.com/cmortuus/halltone/blob/main/PRIVACY.md

## App Privacy ("nutrition label")
- Data collection: **No, we do not collect data from this app.**
- Tracking: **No.**

## Export compliance
`ITSAppUsesNonExemptEncryption = NO` is set in Info.plist, so no questions at upload. (Halltone
uses no encryption; the stream is plain UDP on the local network.)

## Screenshots
6.9" (1320 × 2868), in `docs/app-store/screenshots/`. App Store Connect scales these to smaller
iPhones. Retake with a tidy Mac name (e.g. rename the Mac to "Living Room Mac" temporarily).

## App Review notes
```
Halltone is the iPhone half of a two-part app: it plays audio streamed from the Halltone app for
Mac over the local network. The Mac app is free: https://github.com/cmortuus/halltone/releases/latest

To test:
1. On a Mac running macOS 14.2 or later, open Halltone for Mac. Allow "System Audio Recording"
   when asked. A pairing code appears in its menu bar menu.
2. Put the iPhone on the same Wi-Fi network. Open Halltone, allow Local Network access. The Mac
   appears under "Macs". Tap Connect and enter the pairing code.
3. Play any audio on the Mac (e.g. a YouTube video). It plays on the iPhone.
4. Lock the iPhone: audio continues (this is why the app uses the "audio" background mode).

A demo video of these steps: <ADD LINK BEFORE SUBMITTING>

The app collects no data and makes no internet connections; all traffic is between the iPhone and
the user's Mac on the local network.
```
