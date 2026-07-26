#!/bin/bash
# Privileged half of HyperVibe Setup.app.
# Installs the app and optional microphone stack, then watches coreaudiod and automatically restores
# the previous HAL plug-in if the new one causes a CPU storm.
set -Eeuo pipefail

PAYLOAD="${1:?payload dir required}"
[ -d "$PAYLOAD" ] || { echo "payload not found: $PAYLOAD" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "installer must run as root" >&2; exit 1; }

SUPPORT="/Library/Application Support/SiriRemoteMic"
HAL="/Library/Audio/Plug-Ins/HAL"
DRIVER="SiriRemoteMic.driver"
PLIST_NAME="au.holodata.SiriRemoteMic.captured.plist"
PLIST_DST="/Library/LaunchDaemons/$PLIST_NAME"
DEBUG_PLIST="/Library/Preferences/com.apple.MobileBluetooth.debug.plist"
DEBUG_BACKUP="$SUPPORT/preinstall-HCITraces.plist"
DEBUG_ABSENT_MARKER="$SUPPORT/preinstall-HCITraces.absent"
WATCH_SECONDS="${SRM_WATCH_SECONDS:-25}"
WATCH_THRESHOLD=85
WATCH_STREAK=3

for required in HyperVibe.app "HyperVibe Uninstall.app" "$DRIVER" srm_router \
    srm_captured "$PLIST_NAME" PAYLOAD-SHA256SUMS.txt; do
    [ -e "$PAYLOAD/$required" ] || { echo "missing payload item: $required" >&2; exit 1; }
done

echo "→ verifying installer payload"
(cd "$PAYLOAD" && /usr/bin/shasum -a 256 -c PAYLOAD-SHA256SUMS.txt >/dev/null)

# Downloaded bundles are quarantined as data inside Setup.app. The user has already approved the
# outer installer via Gatekeeper; clear the nested payload so coreaudiod can load the HAL plug-in.
/usr/bin/xattr -dr com.apple.quarantine "$PAYLOAD" 2>/dev/null || true

BACKUP_DIR="$(/usr/bin/mktemp -d /private/tmp/hypervibe-install.XXXXXX)"
DRIVER_BACKUP="$BACKUP_DIR/$DRIVER"
HAD_DRIVER=0
ROLLBACK_ARMED=0

cleanup() {
    /bin/rm -rf "$BACKUP_DIR"
}

coreaudio_cpu() {
    /bin/ps -Ao %cpu=,comm= | /usr/bin/awk '$2 ~ /coreaudiod$/ { total += $1 }
        END { printf "%d", total + 0 }'
}

restart_coreaudio() {
    /usr/bin/killall coreaudiod 2>/dev/null || true
}

rollback_driver() {
    set +e
    echo "→ rolling back Siri Remote Mic HAL plug-in"
    /bin/rm -rf "$HAL/$DRIVER"
    if [ "$HAD_DRIVER" -eq 1 ] && [ -d "$DRIVER_BACKUP" ]; then
        /bin/cp -R "$DRIVER_BACKUP" "$HAL/$DRIVER"
        /usr/sbin/chown -R root:wheel "$HAL/$DRIVER"
    fi
    restart_coreaudio
    /usr/bin/perl -e 'select(undef, undef, undef, 3)'
    ROLLBACK_ARMED=0
}

fail() {
    code="$?"
    trap - ERR INT TERM HUP
    if [ "$ROLLBACK_ARMED" -eq 1 ]; then rollback_driver; fi
    cleanup
    exit "$code"
}
trap fail ERR INT TERM HUP
trap cleanup EXIT

echo "→ installing HyperVibe"
/bin/rm -rf "/Applications/HyperVibe.app" "/Applications/HyperVibe Uninstall.app"
/bin/cp -R "$PAYLOAD/HyperVibe.app" "/Applications/HyperVibe.app"
/bin/cp -R "$PAYLOAD/HyperVibe Uninstall.app" "/Applications/HyperVibe Uninstall.app"

# PacketLogger is never present in public Release assets. Personal transfer packages may include it
# explicitly; install that copy only when the payload actually contains it.
if [ -d "$PAYLOAD/PacketLogger.app" ] && [ ! -d "/Applications/PacketLogger.app" ]; then
    echo "→ installing bundled PacketLogger (personal package)"
    /bin/cp -R "$PAYLOAD/PacketLogger.app" "/Applications/PacketLogger.app"
fi

echo "→ staging microphone services"
/bin/mkdir -p "$SUPPORT" "$HAL"

# Preserve the exact HCITraces value that existed before HyperVibe first managed it. The daemon
# changes only this key; the uninstaller restores it without overwriting unrelated Bluetooth prefs.
if [ ! -e "$DEBUG_BACKUP" ] && [ ! -e "$DEBUG_ABSENT_MARKER" ]; then
    if /usr/bin/defaults read /Library/Preferences/com.apple.MobileBluetooth.debug HCITraces \
        >/dev/null 2>&1; then
        /usr/bin/plutil -extract HCITraces xml1 -o "$DEBUG_BACKUP" "$DEBUG_PLIST"
    else
        /usr/bin/touch "$DEBUG_ABSENT_MARKER"
    fi
fi

/bin/cp "$PAYLOAD/srm_captured" "$SUPPORT/srm_captured"
/bin/cp "$PAYLOAD/srm_router" "$SUPPORT/srm_router"
/usr/sbin/chown root:wheel "$SUPPORT/srm_captured" "$SUPPORT/srm_router"
/bin/chmod 755 "$SUPPORT/srm_captured" "$SUPPORT/srm_router"

if [ -d "$HAL/$DRIVER" ]; then
    HAD_DRIVER=1
    /bin/cp -R "$HAL/$DRIVER" "$DRIVER_BACKUP"
fi

echo "→ installing microphone HAL plug-in"
/bin/rm -rf "$HAL/$DRIVER"
/bin/cp -R "$PAYLOAD/$DRIVER" "$HAL/$DRIVER"
/usr/sbin/chown -R root:wheel "$HAL/$DRIVER"
ROLLBACK_ARMED=1
restart_coreaudio

echo "→ safety check: monitoring coreaudiod for ${WATCH_SECONDS}s"
high=0
peak=0
for ((second = 1; second <= WATCH_SECONDS; second++)); do
    /usr/bin/perl -e 'select(undef, undef, undef, 1)'
    current="$(coreaudio_cpu)"
    [ "$current" -gt "$peak" ] && peak="$current"
    if [ "$current" -ge "$WATCH_THRESHOLD" ]; then
        high=$((high + 1))
    else
        high=0
    fi
    if [ "$high" -ge "$WATCH_STREAK" ]; then
        echo "coreaudiod exceeded ${WATCH_THRESHOLD}% for ${WATCH_STREAK}s (peak ${peak}%)" >&2
        rollback_driver
        echo "microphone plug-in was automatically rolled back" >&2
        exit 2
    fi
done
ROLLBACK_ARMED=0
echo "  coreaudiod stable (peak ${peak}%)"

echo "→ installing capture LaunchDaemon"
/bin/cp "$PAYLOAD/$PLIST_NAME" "$PLIST_DST"
/usr/sbin/chown root:wheel "$PLIST_DST"
/bin/chmod 644 "$PLIST_DST"
/bin/launchctl bootout system "$PLIST_DST" 2>/dev/null || true
/bin/launchctl bootstrap system "$PLIST_DST"

echo "OK"
