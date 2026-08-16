# SiriRemoteForge v0.2.0-beta.1

This beta is a substantial macOS interaction and feedback update. It makes the remote's current
state visible without interrupting the app underneath, expands layer configuration, and gives
pointer and circular-scroll tuning separate, directly editable acceleration curves.

## Choose one download

- **App only:** `HyperVibe-0.2.0-beta.1-macOS-arm64.zip`
  Unzip it, move `HyperVibe.app` to Applications, then right-click → **Open** once.
- **Full Setup (advanced):** `HyperVibe-Full-Setup-0.2.0-beta.1-arm64.zip`
  Includes HyperVibe, Siri Remote Mic, the on-demand voice-capture service, and
  `HyperVibe Uninstall.app`. Installation asks for an administrator password, briefly restarts
  system audio, and verifies `coreaudiod` with automatic plug-in rollback.

Both builds are ad-hoc signed and not Apple-notarized. They require macOS 13 or newer on Apple
silicon and a third-generation USB-C Siri Remote.

## Highlights

### A compact status surface that stays out of the way

- Adds an optional always-on status widget, enabled by default, that shows the current layer at
  rest and the action that actually ran after an input.
- Keeps long-press feedback tied to the physical press lifetime. Progress begins at 0.18 seconds,
  while the configured action threshold remains unchanged, and the selected face stays visible
  until release.
- Uses shared-axis element transitions: icons turn around their vertical centre line, text turns
  around its horizontal centre line, and layer changes roll as one continuous vertical wheel.
- Removes the redundant “Next Layer” intermediary, large page slides, and the external dark shadow.
- Lets the entire widget be dragged, remembers its display and normalized position, and safely
  returns it to an available screen when a monitor is disconnected.

### Voice feedback with real acoustic information

- Expands voice mode into a full-card 25-bar console instead of a decorative level meter.
- Shows real loudness history, relative pitch direction, pitch confidence, spectral brightness,
  and elapsed recording time from the microphone source currently serving Siri Remote Mic.
- Uses indigo–cyan–amber pitch colour, confidence-aware saturation, a brightness cap, and a clear
  red live-recording indicator. Silence settles flat rather than running a looping animation.
- Transforms directly between the layer/action face and the voice console, with no temporary
  completion page or blank transition frame.

### Configurable layers and tuning

- Supports 1–10 ordered layers with custom names and colours. `layerCycle` follows that order and
  loops from the final entry back to the first.
- Keeps legacy layer HUD configuration loadable and migrates it when Settings writes the file.
- Separates pointer and circular-scroll acceleration into two editable graphs, with independent
  curves and an optional shape lock.
- Reworks Settings into a wider desktop layout and adds independent toggles for the compact status
  widget and the larger long-press HUD.

### Input and display reliability

- Deduplicates mirrored HID button edges so one physical press cannot emit the same shortcut
  repeatedly.
- Keeps push-to-talk edge-driven and visible for the complete side-button hold.
- Reduces voice-meter sensitivity to background noise while retaining response to real speech.
- Keeps HUD and widget placement valid across multiple displays and full-screen Spaces.

## Microphone note

Remote Bluetooth voice capture additionally needs Apple's PacketLogger from
[*Additional Tools for Xcode*](https://developer.apple.com/download/all/?q=Additional+Tools+for+Xcode).
PacketLogger is not bundled. The main app and built-in-microphone fallback remain usable without it.

## Verification

- 113 SiriRemoteCore tests passed.
- The complete arm64 macOS app build passed.
- Release archives are checksum-verified, signature-verified, architecture-audited, and scanned for
  private paths, device identifiers, personal configuration, PacketLogger, and production media.

Use the attached `SHA256SUMS.txt` to verify the downloads:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

This remains prerelease software. It relies on private macOS frameworks and an undocumented
Bluetooth voice path; please include the macOS version, remote firmware, and relevant logs when
reporting a reproducible issue.
