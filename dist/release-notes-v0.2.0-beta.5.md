# SiriRemoteForge v0.2.0-beta.5

This beta is a complete redesign of HyperVibe's installation, first-run and recovery experience.
It adds a native macOS Installer, rebuilds the old narrow setup walkthrough into a polished live
System Check, and makes permission health visible throughout the App without spraying prompts
across startup.

## Choose one download

- **Native Full Installer (recommended):**
  `HyperVibe-Full-Setup-0.2.0-beta.5-arm64.pkg`
  Installs HyperVibe, Siri Remote Mic, the on-demand voice-capture service and
  `HyperVibe Uninstall.app` with one administrator approval. It briefly restarts system audio,
  verifies `coreaudiod` for 25 seconds with automatic rollback, then opens System Check.
- **App only:** `HyperVibe-0.2.0-beta.5-macOS-arm64.zip`
  Unzip it, move `HyperVibe.app` to Applications, then Control-click → **Open** once.
- **Legacy Full Setup:** `HyperVibe-Full-Setup-0.2.0-beta.5-arm64.zip`
  Retained for users who cannot use the package. It now finishes in the same System Check instead
  of opening a sequence of blind System Settings dialogs.

These beta artifacts are not Apple-notarized. The App bundles are ad-hoc signed and this beta's
native package is unsigned because the project does not yet have a Developer ID Installer
certificate. Control-click the downloaded package and choose **Open**; never disable Gatekeeper
globally. HyperVibe requires macOS 13 or newer on Apple silicon and a third-generation USB-C Siri
Remote.

## Native, recoverable installation

- Uses Apple's standard Installer UI with bilingual welcome, install detail, license and completion
  pages.
- Verifies the sealed payload and nested App signatures before replacing installed software.
- Preserves an existing `~/.config/siriremote/config.jsonc`; a public default is created only when
  the active user has no configuration, without following config symlinks or recursively changing
  ownership inside the user's home.
- Backs up the existing HyperVibe App, uninstaller, HAL driver, microphone services and LaunchDaemon
  and restores the complete previous set if installation or the audio watchdog fails. The installer
  stops only the HyperVibe UI, never HyperVibe Host.
- Writes installation diagnostics to `/var/log/hypervibe-install.log` and leaves a native
  uninstaller in Applications.

## Redesigned setup and recovery UI

- Replaces the old compact sequence of modal instructions with a spacious native macOS window:
  760 × 680 points by default, responsively resizable from 700 × 620 to 1100 × 900, with only the
  feature list scrolling instead of allowing the entire window to grow beyond the display.
- Organises setup into five purposeful chapters — language, core control access, voice and advanced
  actions, live remote connection, and final readiness — with segmented progress and restrained
  220 ms directional transitions between pages.
- Introduces a consistent visual system of hierarchical SF Symbols, semantic green/orange/red
  status badges, rounded capability cards, clear explanatory copy and dedicated action/settings
  controls. Required and optional capabilities can now be distinguished at a glance.
- Adds a real summary dashboard for install location, core permissions, Siri Remote connection and
  remote voice readiness, plus launch-at-login control and any registration error in the same view.
- Makes the window safely closable and deferable while preventing an incomplete required setup from
  being marked Done. Language choice and completed state are remembered, so returning users resume
  at the relevant health checks instead of repeating onboarding.
- Adds complete English and Simplified Chinese copy for every new state, explanation and recovery
  action. The native Installer's welcome, contents and completion pages are bilingual as well.

## One live System Check

- Separates the two core permissions — Accessibility and Input Monitoring — from optional,
  feature-specific capabilities such as Microphone and Automation.
- Checks Siri Remote Mic components, Apple's separately distributed PacketLogger, remote connection,
  install location and launch-at-login state in one place.
- Requests privacy access only after the user clicks the matching action. Ordinary startup performs
  passive checks and no longer triggers unexplained TCC prompts.
- Refreshes status automatically after returning from System Settings. Granting Accessibility or
  Input Monitoring reattaches the affected event tap or HID manager immediately; no App restart is
  needed.
- Remains available from a new **Open System Check…** item in both the menu bar and Settings, or via
  `HyperVibe --system-check` for diagnostics and support workflows.
- Adds a persistent **Permissions: Ready** / **Permissions: Action needed** line to the menu bar.
  When action is needed, the status itself is clickable and opens the exact recovery surface.
- Detects a later permission revocation on launch instead of silently leaving pointer or button
  control broken. Normal health polling remains passive and never causes a TCC dialog by itself.

## Microphone note

Remote Bluetooth voice capture additionally needs Apple's PacketLogger from
[*Additional Tools for Xcode*](https://developer.apple.com/download/all/?q=Additional+Tools+for+Xcode).
Apple does not permit redistributing it, so it is not bundled. System Check reports whether it is
installed and links to Apple's download; pointer, scrolling, buttons and built-in-microphone
fallback remain available without it.

## Verification

- SiriRemoteCore passes all 129 tests.
- The complete arm64 App, microphone router, HAL plug-in and capture daemon build successfully for
  macOS 13 or newer.
- All three binary downloads are checksum-verified. Release audit expands the native package and
  both archives, verifies nested signatures and the payload seal, checks Installer XML and scripts,
  compares package/App binaries byte-for-byte, and rejects personal configuration, PacketLogger,
  device identifiers, private paths or production media.
- A stable-signed local build was installed and restarted separately without changing the existing
  Accessibility or Input Monitoring identity; HID detection and the media-key event tap reattached
  successfully.

Use the attached `SHA256SUMS.txt` to verify the downloads:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

This remains prerelease software. It relies on private macOS frameworks and an undocumented
Bluetooth voice path; please include the macOS version, remote firmware and relevant logs when
reporting a reproducible issue.
