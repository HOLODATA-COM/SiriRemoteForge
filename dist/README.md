# dist — one-app installer for another Mac

Produces a double-clickable **`HyperVibe Setup.app`** that installs the whole system on another
**Apple-silicon** Mac: the menu-bar app, the virtual-mic HAL plug-in, the router, and the on-demand
capture daemon — with a single admin password prompt — then guides the user through the permissions
macOS will not let an app grant itself.

## Build the package (on this Mac)

```sh
# 1. make sure the components are built (only if missing):
(cd app         && ./create_app_bundle.sh)
(cd mic/router  && ./build.sh)
(cd mic/driver  && ./build.sh)
(cd mic/captured && ./build.sh)

# 2. assemble the installer:
dist/package.sh                       # clean/redistributable (target downloads PacketLogger itself)
# or, for your OWN machines, bundle this Mac's PacketLogger so the target needs no download:
SRM_BUNDLE_PACKETLOGGER=1 dist/package.sh
```

Output: `dist/build/HyperVibe Setup.app` and `dist/build/HyperVibe-Setup.zip` (send the zip).

## On the other Mac

1. **PacketLogger** (for the remote-mic voice feature): if you built with
   `SRM_BUNDLE_PACKETLOGGER=1`, it is installed automatically — skip this step. Otherwise download it
   from Apple's free *Additional Tools for Xcode* (developer.apple.com, Apple ID login) and drag
   `PacketLogger.app` into `/Applications`; the installer offers the link if it is still missing.
   PacketLogger is Apple's tool — bundling it is fine for your own machines, not for public
   redistribution.
2. Unzip, then **right-click `HyperVibe Setup.app` → Open → Open** (one-time Gatekeeper bypass for a
   self-signed app).
3. Enter the admin password once when asked.
4. Toggle the 3 permission switches it walks you to (Accessibility, Input Monitoring, Microphone).
5. Pair the Siri Remote in Bluetooth settings.

## What it does / limits

- **Auto:** copies the app + plug-in + daemon, loads the daemon, restarts coreaudiod, writes the
  default config, de-quarantines everything, launches HyperVibe.
- **Manual (macOS hard rules):** the 3 permission toggles, and obtaining PacketLogger.
- **Arch:** the payload is arm64. An Intel target needs a rebuild-on-target flow instead.
- **Signing:** ad-hoc (no paid account) → the one-time right-click→Open on first launch.
