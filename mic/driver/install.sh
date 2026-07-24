#!/bin/bash
# Install the "Siri Remote Mic" HAL plug-in. Persistent system component: it lives in
# /Library/Audio/Plug-Ins/HAL and survives reboots until ./uninstall.sh removes it.
# Restarting coreaudiod briefly interrupts all audio on the machine.
#
# This script is intentionally fail-closed after the 2026-07-23 CoreAudio notification storm.
# Building and running the process-local contract test never require this script.
set -euo pipefail
cd "$(dirname "$0")"
DRIVER="SiriRemoteMic.driver"
DEST="/Library/Audio/Plug-Ins/HAL"
SYSTEM_SETTINGS="/Library/Preferences/Audio/com.apple.audio.SystemSettings.plist"
ACKNOWLEDGEMENT="I_UNDERSTAND_THIS_RESTARTS_SYSTEM_AUDIO"

[ -d "$DRIVER" ] || { echo "build first: ./build.sh"; exit 1; }

if [ "${SRM_SYSTEM_INSTALL_ACK:-}" != "$ACKNOWLEDGEMENT" ]; then
    echo "REFUSED: system installation is disabled by default."
    echo "It installs code into coreaudiod and restarts audio for the whole Mac."
    echo "Only after explicit approval for a new system test, run:"
    echo "  SRM_SYSTEM_INSTALL_ACK=$ACKNOWLEDGEMENT ./install.sh"
    exit 2
fi

if [ -e "$DEST/$DRIVER" ]; then
    echo "REFUSED: $DEST/$DRIVER already exists; do not overwrite a live HAL plug-in."
    echo "Inspect it and use ./uninstall.sh deliberately before any replacement."
    exit 2
fi

if [ -r "$SYSTEM_SETTINGS" ]; then
    PREFERRED_INPUT_UID=$(
        /usr/libexec/PlistBuddy \
            -c "Print :'preferred devices':input:0:uid" \
            "$SYSTEM_SETTINGS" 2>/dev/null || true
    )
    if [ "$PREFERRED_INPUT_UID" = "SiriRemoteMic_UID" ] &&
       [ "${SRM_STALE_PREFERRED_UID_ACK:-}" != "I_ACCEPT_THE_STALE_PREFERRED_UID_RISK" ]; then
        echo "REFUSED: macOS still records SiriRemoteMic_UID as preferred input #0."
        echo "Reinstalling could make an unverified plug-in the default input immediately."
        echo "Do not bypass this gate without a separate, explicit test decision and rollback plan."
        exit 2
    fi
fi

sudo cp -R "$DRIVER" "$DEST/"
sudo killall coreaudiod 2>/dev/null || true
echo "✓ installed → $DEST/$DRIVER ; coreaudiod restarted"
echo "verify: System Settings → Sound → Input  (or: system_profiler SPAudioDataType)"
