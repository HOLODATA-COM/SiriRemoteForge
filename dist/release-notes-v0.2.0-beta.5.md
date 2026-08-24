# SiriRemoteForge v0.2.0-beta.5

This beta makes first installation and permission recovery substantially clearer. HyperVibe now
ships a native macOS Installer and one live System Check that explains, requests and verifies each
capability without spraying permission prompts across startup.

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
- Remains available from the menu bar, Settings and `HyperVibe --system-check`. The menu bar also
  exposes a persistent Ready / Action needed health line.

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
