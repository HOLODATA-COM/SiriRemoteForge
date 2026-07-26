# SiriRemoteForge v0.1.0-beta.1

First public beta binary build for Apple-silicon Macs.

## Choose one download

- **App only:** `HyperVibe-0.1.0-beta.1-macOS-arm64.zip`
  Unzip, move `HyperVibe.app` to Applications, then right-click → **Open** once.
- **Full Setup (advanced):** `HyperVibe-Full-Setup-0.1.0-beta.1-arm64.zip`
  Adds Siri Remote Mic, the on-demand voice-capture service, and
  `HyperVibe Uninstall.app`. It requires an administrator password, briefly restarts system audio,
  and runs a 25-second `coreaudiod` safety check with automatic plug-in rollback.

Both builds are ad-hoc signed and not Apple-notarized. macOS 13+ and a 3rd-generation USB-C Siri
Remote are required. This beta is arm64 only.

## Highlights

- Remap the remote's buttons, click ring, trackpad, swipes, and taps.
- Per-app profiles and composable layers.
- Tap, double-tap, triple-tap, and three release-to-select long-press stages.
- Accelerated cursor movement and circular scrolling, including Layer 1 horizontal ring scrolling.
- Dynamic long-press HUD, radial app launcher, sticky drag, window/Space controls, and live settings.
- Siri Remote Mic automatically crossfades between remote voice and the Mac's built-in microphone.

## Microphone note

Remote voice capture additionally needs Apple's PacketLogger from
[*Additional Tools for Xcode*](https://developer.apple.com/download/all/?q=Additional+Tools+for+Xcode).
It is not bundled. The app and built-in-microphone fallback remain usable without it.

## Verify downloads

Use the attached `SHA256SUMS.txt`:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

This is prerelease software that uses private macOS frameworks and an undocumented Bluetooth voice
path. Please report reproducible issues with the macOS version, remote firmware, and relevant logs.
