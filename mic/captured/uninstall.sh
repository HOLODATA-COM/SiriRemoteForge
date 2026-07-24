#!/bin/bash
# uninstall.sh — remove the "Siri Remote Mic" capture daemon. Needs sudo.
set -e
PLIST_DST="/Library/LaunchDaemons/au.holodata.SiriRemoteMic.captured.plist"
sudo launchctl unload -w "$PLIST_DST" 2>/dev/null || true
sudo rm -f "$PLIST_DST"
sudo rm -rf "/Library/Application Support/SiriRemoteMic"
echo "✓ daemon removed (the HAL plug-in and its demand notification are untouched)"
