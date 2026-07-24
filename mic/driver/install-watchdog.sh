#!/bin/bash
# Safe, watchdog-protected install of the "Siri Remote Mic" HAL plug-in.
#
# WHY THIS EXISTS: a test of the *unfixed* bundle once drove coreaudiod over 100% CPU
# (a property/reconciliation storm) and required a reboot. The bundle is fixed and
# validated now, but any HAL install is a system-level act — so this installs the plug-in
# and then watches coreaudiod's CPU, automatically UNINSTALLING if it storms. Uses
# interactive sudo (you type your password). Restarting coreaudiod briefly blips all audio.
set +e
cd "$(dirname "$0")"
DRIVER="SiriRemoteMic.driver"
DEST="/Library/Audio/Plug-Ins/HAL"
WINDOW="${SRM_WATCH_SECONDS:-25}"     # seconds to monitor after load
THRESH=85                             # coreaudiod %CPU considered "storming"
STREAK=3                              # consecutive seconds over THRESH => rollback

cpu() { ps -Ao %cpu,comm | awk '/coreaudiod$/{s+=$1} END{printf "%d", s+0}'; }
rollback() {
    echo ">>> ROLLBACK: removing plug-in + restarting coreaudiod"
    sudo rm -rf "$DEST/$DRIVER"
    sudo killall coreaudiod 2>/dev/null
    perl -e 'select(undef,undef,undef,3)'
    local c; c=$(cpu); echo ">>> post-rollback coreaudiod=${c}%"
    [ "$c" -ge 80 ] && echo ">>> !!! STILL HIGH — a REBOOT may be required (prior-incident behaviour) !!!"
}

[ -d "$DRIVER" ] || { echo "build first: ./build.sh"; exit 1; }
if [ -e "$DEST/$DRIVER" ]; then
    echo "already installed at $DEST/$DRIVER — run ./uninstall.sh first if you mean to replace it."
    exit 1
fi

echo "authenticating sudo (needed for instant rollback under load)…"
sudo -v || exit 1
echo "baseline coreaudiod=$(cpu)%"

echo ">>> installing + restarting coreaudiod"
sudo cp -R "$DRIVER" "$DEST/"
sudo killall coreaudiod 2>/dev/null

HIGH=0; PEAK=0
for i in $(seq 1 "$WINDOW"); do
    perl -e 'select(undef,undef,undef,1)'
    C=$(cpu); [ "$C" -gt "$PEAK" ] && PEAK=$C
    echo "t=${i}s coreaudiod=${C}% (peak ${PEAK}%)"
    if [ "$C" -ge "$THRESH" ]; then HIGH=$((HIGH+1)); else HIGH=0; fi
    if [ "$HIGH" -ge "$STREAK" ]; then
        echo ">>> STORM (>=${THRESH}% for ${STREAK}s)"; rollback
        echo "VERDICT: STORM — rolled back. Do not reinstall without investigating."; exit 2
    fi
done

echo "VERDICT: STABLE for ${WINDOW}s (peak coreaudiod ${PEAK}%). Plug-in installed."
system_profiler SPAudioDataType 2>/dev/null | grep -A4 "Siri Remote Mic"
echo "remove with ./uninstall.sh"
