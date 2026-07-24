#!/bin/bash
# do_install.sh — the privileged half of "HyperVibe Setup.app".
# Runs as ROOT (invoked via AppleScript `do shell script … with administrator privileges`).
#   $1 = payload dir inside the installer bundle (…/HyperVibe Setup.app/Contents/Resources/payload)
# Idempotent: safe to re-run. Restarts coreaudiod (briefly blips all audio) to load the plug-in.
set -e
PAYLOAD="${1:?payload dir required}"
[ -d "$PAYLOAD" ] || { echo "payload not found: $PAYLOAD" >&2; exit 1; }

SUPPORT="/Library/Application Support/SiriRemoteMic"
HAL="/Library/Audio/Plug-Ins/HAL"
DRIVER="SiriRemoteMic.driver"
PLIST_NAME="au.holodata.SiriRemoteMic.captured.plist"
PLIST_DST="/Library/LaunchDaemons/$PLIST_NAME"

# 0. De-quarantine the payload. Files transferred to another Mac (AirDrop/download/unzip) get the
#    com.apple.quarantine xattr; a quarantined HAL plug-in silently fails to load in coreaudiod.
/usr/bin/xattr -dr com.apple.quarantine "$PAYLOAD" 2>/dev/null || true

# 1. Menu-bar app → /Applications
rm -rf "/Applications/HyperVibe.app"
cp -R "$PAYLOAD/HyperVibe.app" "/Applications/HyperVibe.app"

# 1b. PacketLogger (Apple's HCI tool) — only if this build bundled it AND the target lacks it.
#     Apple-signed + universal, so it installs cleanly; never overwrite an existing copy.
if [ -d "$PAYLOAD/PacketLogger.app" ] && [ ! -d "/Applications/PacketLogger.app" ]; then
    cp -R "$PAYLOAD/PacketLogger.app" "/Applications/PacketLogger.app"
fi

# 2. HAL plug-in (coreaudiod restart at step 5 loads it)
mkdir -p "$HAL"
rm -rf "$HAL/$DRIVER"
cp -R "$PAYLOAD/$DRIVER" "$HAL/"
chown -R root:wheel "$HAL/$DRIVER"

# 3. Capture daemon + router
mkdir -p "$SUPPORT"
cp "$PAYLOAD/srm_captured" "$SUPPORT/srm_captured"
cp "$PAYLOAD/srm_router"   "$SUPPORT/srm_router"
chown root:wheel "$SUPPORT/srm_captured" "$SUPPORT/srm_router"
chmod 755 "$SUPPORT/srm_captured" "$SUPPORT/srm_router"

# 4. LaunchDaemon (root, on-demand capture)
cp "$PAYLOAD/$PLIST_NAME" "$PLIST_DST"
chown root:wheel "$PLIST_DST"
chmod 644 "$PLIST_DST"
launchctl unload -w "$PLIST_DST" 2>/dev/null || true
launchctl load -w "$PLIST_DST"

# 5. Restart coreaudiod so it loads the freshly-installed plug-in
killall coreaudiod 2>/dev/null || true

echo "OK"
