# SiriRemoteForge v0.2.0-beta.3

This beta polishes HyperVibe's always-on status surface and completes the move to one portable,
hot-reloading JSON configuration. The widget now preserves a readable layer identity in every
state, uses materially connected element transitions, and adapts its contrast to the real macOS
material behind it without screen capture permission.

## Choose one download

- **App only:** `HyperVibe-0.2.0-beta.3-macOS-arm64.zip`
  Unzip it, move `HyperVibe.app` to Applications, then right-click → **Open** once.
- **Full Setup (advanced):** `HyperVibe-Full-Setup-0.2.0-beta.3-arm64.zip`
  Includes HyperVibe, Siri Remote Mic, the on-demand voice-capture service, and
  `HyperVibe Uninstall.app`. Installation asks for an administrator password, briefly restarts
  system audio, and verifies `coreaudiod` with automatic plug-in rollback.

Both builds are ad-hoc signed and not Apple-notarized. They require macOS 13 or newer on Apple
silicon and a third-generation USB-C Siri Remote.

## Highlights

### A more legible, continuous status widget

- Keeps a subtle, layer-coloured edge around the complete card in idle, action, hold, and voice
  states, so the active layer remains identifiable without reading the label.
- Keeps the card's physical size fixed. Transitions reconstruct only the icon and text, preventing
  the surrounding layer aura from drifting or scaling separately from the material surface.
- Turns each icon as one two-sided object through its vertical centre axis; text uses connected
  glyph motion and a compact horizontal-axis fold instead of a blurred page replacement.
- Synchronizes temporary animation snapshots with the permanent AppKit labels, removing the
  one-frame weight, position, and brightness jump at transition completion.
- Uses `NSVisualEffectView.interiorBackgroundStyle`, semantic label colours, and the effective
  appearance to stay readable over both light and dark app content. No screen recording or screen
  sampling is used.
- Preserves the red live-recording dot while voice labels and waveform accents adapt to the current
  material contrast.

### Every formal preference in `config.jsonc`

- Adds JSON-backed `interfaceLanguage`, `launchAtLoginEnabled`, and `menuBarIconEnabled` settings.
- Adds independent `layerHUDEnabled` and `dragIndicatorEnabled` switches alongside the existing
  `statusWidgetEnabled`, `holdHUDEnabled`, and `findCursorEnabled` controls.
- Adds `showSetupWizardOnFirstLaunch`; the one-time completion flag remains local to each Mac.
- Applies language, Login Item registration, and every status-surface visibility change live, and
  writes GUI changes back through the same atomic config save path.
- Keeps only machine-local state outside portable JSON: the dragged widget position (which contains
  a display ID) and whether that Mac has already completed onboarding.
- Rejects unknown interface-language values instead of silently falling back.

## Microphone note

Remote Bluetooth voice capture additionally needs Apple's PacketLogger from
[*Additional Tools for Xcode*](https://developer.apple.com/download/all/?q=Additional+Tools+for+Xcode).
PacketLogger is not bundled. The main app and built-in-microphone fallback remain usable without it.

## Verification

- 125 SiriRemoteCore tests passed, including JSON defaults, overrides, validation, and stable
  write-back for the new interface settings.
- The complete arm64 macOS app build passed and the stable local development build was restarted.
- Release archives are checksum-verified, signature-verified, architecture-audited, and scanned for
  private paths, device identifiers, personal configuration, PacketLogger, and production media.

Use the attached `SHA256SUMS.txt` to verify the downloads:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

This remains prerelease software. It relies on private macOS frameworks and an undocumented
Bluetooth voice path; please include the macOS version, remote firmware, and relevant logs when
reporting a reproducible issue.
