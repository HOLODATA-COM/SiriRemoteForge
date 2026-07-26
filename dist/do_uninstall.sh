#!/bin/bash
# Privileged half of HyperVibe Uninstall.app.
# Removes installed binaries and restores the Bluetooth HCITraces preference. User configuration
# and Apple's separately-downloaded PacketLogger are intentionally preserved.
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "uninstaller must run as root" >&2; exit 1; }

SUPPORT="/Library/Application Support/SiriRemoteMic"
DRIVER="/Library/Audio/Plug-Ins/HAL/SiriRemoteMic.driver"
PLIST="/Library/LaunchDaemons/au.holodata.SiriRemoteMic.captured.plist"
DEBUG_PLIST="/Library/Preferences/com.apple.MobileBluetooth.debug.plist"
DEBUG_BACKUP="$SUPPORT/preinstall-HCITraces.plist"
DEBUG_ABSENT_MARKER="$SUPPORT/preinstall-HCITraces.absent"

echo "→ stopping capture daemon"
/bin/launchctl bootout system "$PLIST" 2>/dev/null || true
/bin/rm -f "$PLIST"

echo "→ restoring Bluetooth trace preference"
if [ -f "$DEBUG_BACKUP" ]; then
    /usr/bin/defaults delete /Library/Preferences/com.apple.MobileBluetooth.debug HCITraces \
        2>/dev/null || true
    [ -f "$DEBUG_PLIST" ] || /usr/bin/plutil -create xml1 "$DEBUG_PLIST"
    hci_traces_xml="$(/bin/cat "$DEBUG_BACKUP")"
    /usr/bin/plutil -insert HCITraces -xml "$hci_traces_xml" "$DEBUG_PLIST"
elif [ -f "$DEBUG_ABSENT_MARKER" ]; then
    /usr/bin/defaults delete /Library/Preferences/com.apple.MobileBluetooth.debug HCITraces \
        2>/dev/null || true
fi

echo "→ removing HyperVibe and microphone components"
/bin/rm -rf "$DRIVER" "$SUPPORT" "/Applications/HyperVibe.app"
/bin/rm -f /var/log/srm_captured.log
/usr/bin/killall coreaudiod 2>/dev/null || true
/usr/bin/killall -30 bluetoothd 2>/dev/null || true

# Remove the installed uninstaller last. Its process and this already-open script can finish safely.
/bin/rm -rf "/Applications/HyperVibe Uninstall.app"

echo "OK"
