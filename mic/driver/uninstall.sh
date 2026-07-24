#!/bin/bash
# Remove the "Siri Remote Mic" HAL plug-in and restart coreaudiod.
set -e
DEST="/Library/Audio/Plug-Ins/HAL/SiriRemoteMic.driver"
sudo rm -rf "$DEST"
sudo killall coreaudiod 2>/dev/null || true
echo "✓ removed $DEST ; coreaudiod restarted"
