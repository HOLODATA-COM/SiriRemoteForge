# Release packaging

The release builder creates two Apple-silicon macOS downloads from a clean checkout:

- **`HyperVibe-VERSION-macOS-arm64.zip`** — the menu-bar app only. Unzip, move
  `HyperVibe.app` to Applications, then right-click it and choose **Open** the first time.
- **`HyperVibe-Full-Setup-VERSION-arm64.zip`** — the app plus the Siri Remote Mic HAL plug-in,
  router, capture daemon, and an uninstaller. This is the advanced option because it installs
  system audio and Bluetooth-capture components with an administrator password.

`SHA256SUMS.txt` covers both archives. GitHub supplies source archives separately.

## Build public Release assets

The only local prerequisite is Xcode command-line tools. The builder downloads the official,
checksum-pinned libopus 1.6.1 source, compiles it for macOS 13, and links it statically into the
shipping router. Neither the build Mac nor the destination Mac needs Homebrew.

```sh
dist/build-release.sh 0.1.0-beta.1
```

The command requires a clean worktree, rebuilds every shipping binary, injects the numeric app
version, uses reproducible ad-hoc signing in an isolated staging bundle, runs the router and HAL
offline tests, and writes:

```text
dist/build/0.1.0-beta.1/
├── HyperVibe-0.1.0-beta.1-macOS-arm64.zip
├── HyperVibe-Full-Setup-0.1.0-beta.1-arm64.zip
└── SHA256SUMS.txt
```

Generated output remains ignored by Git because personal packages may contain private material.
Upload only the three audited files above, never the whole `dist/build/` directory.
`build-release.sh` finishes by running `audit-release.sh`, which independently extracts both
archives and fails on invalid signatures/checksums, wrong versions or architectures, Homebrew
runtime links, missing license notices, private paths, author config, PacketLogger, or video files.
The libopus source archive and build output are cached under ignored `dist/build/` paths.
The builder never rewrites `app/HyperVibe.app`, so a locally running, stable-signed development App
and its macOS privacy grants are left untouched.

## Public-package safety boundary

Public mode is the default. It always uses `examples/config.jsonc` and refuses both a custom config
and PacketLogger. The payload has its own SHA-256 manifest, which the privileged installer verifies
before changing the system.

The Full Setup installer:

1. installs the app and `HyperVibe Uninstall.app`;
2. preserves the pre-existing Bluetooth `HCITraces` preference;
3. installs the HAL plug-in and restarts `coreaudiod`;
4. monitors `coreaudiod` for 25 seconds and restores the previous plug-in if CPU remains at or above
   85% for three consecutive seconds;
5. installs the on-demand capture daemon only after that check passes.

The uninstaller removes the app, HAL plug-in, daemon, and support binaries, then restores the prior
`HCITraces` value. It intentionally keeps the user's `~/.config/siriremote` directory and Apple's
separately installed PacketLogger.

If PacketLogger is absent, the installed daemon leaves Bluetooth HCI debug traces unchanged and
remote voice stays disabled. Installing PacketLogger later activates trace capture lazily on the
next microphone demand; no reboot is required.

## PacketLogger and remote voice

Remote voice capture needs Apple's PacketLogger from
[*Additional Tools for Xcode*](https://developer.apple.com/download/all/?q=Additional+Tools+for+Xcode)
at `/Applications/PacketLogger.app`. It is not redistributable as part of this public project and is
never included in public Release assets. Full Setup offers Apple's download page if it is missing;
the app and built-in-microphone fallback still work without it.

For a private transfer between machines you control, packaging a local config and, subject to
Apple's license, an existing PacketLogger copy is an explicit separate mode:

```sh
dist/package.sh --personal --version local --config /path/to/config.jsonc
dist/package.sh --personal --version local --config /path/to/config.jsonc --with-packetlogger
```

Personal output prints a warning and must never be uploaded to GitHub.

## Signing and Gatekeeper

These beta archives are ad-hoc signed, not Apple-notarized. The hardened runtime is intentionally
disabled because it terminates the private MultitouchSupport callback used by the remote trackpad.
On first launch, use **right-click → Open**. Do not tell users to globally disable Gatekeeper.
