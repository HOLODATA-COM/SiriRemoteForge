# SiriRemoteForge v0.2.0-beta.4

This beta makes HyperVibe's visual feedback truthful under rapid input. Action symbols now follow
the action's meaning and measured system state, while long-press selection, progress and destination
artwork advance from the same monotonic clock. It also adds relative display-brightness controls and
the repository's new software-focused product website.

## Choose one download

- **App only:** `HyperVibe-0.2.0-beta.4-macOS-arm64.zip`
  Unzip it, move `HyperVibe.app` to Applications, then right-click → **Open** once.
- **Full Setup (advanced):** `HyperVibe-Full-Setup-0.2.0-beta.4-arm64.zip`
  Includes HyperVibe, Siri Remote Mic, the on-demand voice-capture service, and
  `HyperVibe Uninstall.app`. Installation asks for an administrator password, briefly restarts
  system audio, and verifies `coreaudiod` with automatic plug-in rollback.

Both builds are ad-hoc signed and not Apple-notarized. They require macOS 13 or newer on Apple
silicon and a third-generation USB-C Siri Remote.

## Highlights

### Semantic, state-aware feedback

- Gives every action one deterministic semantic colour and motion vocabulary across the compact
  widget, long-press HUD and Layer HUD. Destructive actions are red, navigation is blue, media is
  pink, pointer operations are teal, and reversible caution states are orange.
- Uses Apple's authored SF Symbol layers and topology-aware replacement where the source and
  destination genuinely belong to one symbol family. Unrelated actions keep a restrained compositor
  transition instead of briefly merging into a malformed glyph.
- Makes volume and brightness describe the measured system level. Repeated ticks update one stable
  face without replaying its entrance, and volume-up/down retain identical symbol geometry.
- Presents Mute or Unmute once from the predicted post-toggle state, then uses CoreAudio only to
  confirm or correct the result. Rapid presses cannot let an older delayed sample win.
- Rebuilds the three Layer sheets in place, reveals App Wheel's nine dots as a relay, preserves
  semantic colour in the large water HUD, and keeps the widget frame and Layer aura fixed.

### Long-press feedback on one clock

- Resolves the action, whole-card progress surface and large HUD from the same elapsed-time sample.
  A busy main queue can no longer advance the water while Close, Quit or Cancel artwork waits behind
  a separate timer.
- Jumps directly to the stage valid at the current instant after a late frame instead of replaying
  missed faces. The first visible frame also reflects what releasing at that instant would execute.
- Keeps the accepted 0.18-second visual lead and the 0.5-second default first-stage threshold, while
  the Play/Pause → Music binding now owns its faster 0.3-second delay without changing other holds.

### Layer 3 brightness and public website

- Adds the JSON action `{ "action": "brightnessStep", "to": "up|down" }`. The maintained Layer 3
  mappings use it for the plus/minus buttons, preserving the current display level and moving by one
  native brightness notch per press.
- Adds the static `website/` product page with current App captures and native looping feedback. It
  explains touchpad movement, accelerated ring scrolling, sticky drag, multi-stage gestures,
  App × Layer resolution, live voice features, acceleration curves and Agent-editable JSONC without
  scroll-scrubbed scenes or hardware-material claims.
- Prevents LaunchServices from opening duplicate menu-bar instances when Login Items and a manual
  reopen converge.

## Microphone note

Remote Bluetooth voice capture additionally needs Apple's PacketLogger from
[*Additional Tools for Xcode*](https://developer.apple.com/download/all/?q=Additional+Tools+for+Xcode).
PacketLogger is not bundled. The main app and built-in-microphone fallback remain usable without it.

## Verification

- SiriRemoteCore's complete test suite passes, including brightness-action round trips, maintained
  example mappings, exact hold boundaries and skipped-frame regressions.
- The complete arm64 macOS App, microphone router, HAL plug-in and capture daemon build successfully.
- Both public archives are checksum-verified, deep signature-verified, architecture-audited, and
  scanned for private paths, device identifiers, personal configuration, PacketLogger and production
  film assets.
- The website passes desktop and phone browser checks with no console errors, broken resources or
  horizontal overflow; reduced-motion content remains visible.

Use the attached `SHA256SUMS.txt` to verify the downloads:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

This remains prerelease software. It relies on private macOS frameworks and an undocumented
Bluetooth voice path; please include the macOS version, remote firmware, and relevant logs when
reporting a reproducible issue.
