# SiriRemoteForge v0.2.0-beta.2

This beta makes the Settings GUI safer and much faster to configure: every save now has visible
feedback, and shortcut actions can be recorded directly from the physical keyboard instead of
being typed as configuration tokens.

## Choose one download

- **App only:** `HyperVibe-0.2.0-beta.2-macOS-arm64.zip`
  Unzip it, move `HyperVibe.app` to Applications, then right-click → **Open** once.
- **Full Setup (advanced):** `HyperVibe-Full-Setup-0.2.0-beta.2-arm64.zip`
  Includes HyperVibe, Siri Remote Mic, the on-demand voice-capture service, and
  `HyperVibe Uninstall.app`. Installation asks for an administrator password, briefly restarts
  system audio, and verifies `coreaudiod` with automatic plug-in rollback.

Both builds are ad-hoc signed and not Apple-notarized. They require macOS 13 or newer on Apple
silicon and a third-generation USB-C Siri Remote.

## Highlights

### Record shortcuts from the keyboard

- Keystroke, Push-to-talk, and Repeat Key actions now use a native macOS shortcut recorder.
- Click the field and press the intended combination; the normalized shortcut is saved immediately.
- Preserves left/right Command, Control, Option, and Shift so side-sensitive hyperkeys still work.
- Supports standalone modifier chords, **Fn**, Fn combinations, navigation keys, punctuation,
  Forward Delete, Help, and F1–F20.
- Escape cancels recording, an unmodified Delete clears it, and the pencil button opens an advanced
  text fallback for pasting or manually editing a chord.

### Know when configuration is saved

- The Settings header now reports **Saving…**, **Auto-saved**, or **Save failed** across both tabs.
- Failed saves stay visible and expose the exact error when clicked.
- Tuning remains live and uses its existing short debounce; Layout changes save when the control
  commits. Both continue to write the single `config.jsonc` source of truth atomically.
- Invalid existing JSONC is never overwritten, and the GUI now explains why the save was refused.

## Microphone note

Remote Bluetooth voice capture additionally needs Apple's PacketLogger from
[*Additional Tools for Xcode*](https://developer.apple.com/download/all/?q=Additional+Tools+for+Xcode).
PacketLogger is not bundled. The main app and built-in-microphone fallback remain usable without it.

## Verification

- 124 SiriRemoteCore tests passed, including shortcut normalization and physical Fn capture.
- The complete arm64 macOS app build passed.
- The native AppKit recorder bridge passed synthetic `NSEvent` tests for ordinary chords,
  side-specific modifiers, Fn + F12, standalone Fn, cancellation, and clearing.
- Release archives are checksum-verified, signature-verified, architecture-audited, and scanned for
  private paths, device identifiers, personal configuration, PacketLogger, and production media.

Use the attached `SHA256SUMS.txt` to verify the downloads:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

This remains prerelease software. It relies on private macOS frameworks and an undocumented
Bluetooth voice path; please include the macOS version, remote firmware, and relevant logs when
reporting a reproducible issue.
