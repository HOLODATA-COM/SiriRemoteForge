#!/bin/bash
#
# live_device_test.sh — end-to-end live test of the "Siri Remote Mic" HAL device.
#
# Chain under test:  remote → packetlogger -o (lossless) → srm_router → shm ring
#                    → SiriRemoteMic.driver ReadInput (position-based, FIXED) → coreaudiod
#                    → ffmpeg (avfoundation) → WAV + objective spike/discontinuity analysis.
#
# PRECONDITION: the FIXED driver bundle must be the one coreaudiod has loaded. This script
# verifies the installed binary is byte-identical to the freshly built one and stops with
# instructions if not. It never installs anything itself.
#
# Usage: ./live_device_test.sh [record_seconds]   # default 15; hold Siri and speak.
#
set -uo pipefail
cd "$(dirname "$0")"

SECONDS_TO_RECORD="${1:-15}"
INSTALLED="/Library/Audio/Plug-Ins/HAL/SiriRemoteMic.driver/Contents/MacOS/SiriRemoteMic"
BUILT="SiriRemoteMic.driver/Contents/MacOS/SiriRemoteMic"
ROUTER="../router/srm_router"
PL="/Applications/PacketLogger.app/Contents/Resources/packetlogger"
PKLG="/tmp/srm_device_test_$$.pklg"
WAV="/tmp/srm_device_test.wav"
ROUTER_LOG="/tmp/srm_device_test_router.log"

command -v ffmpeg >/dev/null || { echo "live_device_test: ffmpeg not found" >&2; exit 1; }
[ -x "$PL" ] || { echo "live_device_test: packetlogger not found" >&2; exit 1; }
[ -f "$BUILT" ] || { echo "live_device_test: build first: ./build.sh" >&2; exit 1; }
[ -x "$ROUTER" ] || { echo "live_device_test: build the router first: (cd ../router && ./build.sh)" >&2; exit 1; }

if [ ! -f "$INSTALLED" ]; then
    echo "live_device_test: driver not installed. Install the FIXED build first:" >&2
    echo "    ./install-watchdog.sh" >&2
    exit 1
fi
if ! cmp -s "$INSTALLED" "$BUILT"; then
    echo "live_device_test: INSTALLED driver differs from the current build (it predates the" >&2
    echo "ReadInput fix, or is stale). Reinstall the fixed build first:" >&2
    echo "    ./uninstall.sh && ./install-watchdog.sh" >&2
    exit 1
fi

cleanup() {
    [ -n "${ROUTER_PID:-}" ] && kill -INT "$ROUTER_PID" 2>/dev/null
    [ -n "${CAP_PID:-}" ] && sudo kill "$CAP_PID" 2>/dev/null
    sudo pkill -f "packetlogger convert -o $PKLG" 2>/dev/null
    rm -f "$PKLG"
}
trap cleanup EXIT INT TERM

echo "live_device_test: HCI capture needs sudo — enter your password if prompted."
sudo -v || exit 1

echo "live_device_test: starting lossless capture → $PKLG"
sudo "$PL" convert -o "$PKLG" &
CAP_PID=$!
for _ in $(seq 1 100); do [ -s "$PKLG" ] && break; sleep 0.05; done
if [ ! -s "$PKLG" ]; then
    echo "live_device_test: capture did not start writing — enable the Bluetooth HCI debug" >&2
    echo "defaults (com.apple.MobileBluetooth.debug HCITraces) first." >&2
    exit 1
fi

echo "live_device_test: starting router (feeds the device's shared-memory ring)"
"$ROUTER" --pklg "$PKLG" > "$ROUTER_LOG" 2>&1 &
ROUTER_PID=$!
sleep 0.5
kill -0 "$ROUTER_PID" 2>/dev/null || { echo "router died:"; cat "$ROUTER_LOG"; exit 1; }

echo
echo "live_device_test: RECORDING ${SECONDS_TO_RECORD}s from the device NOW —"
echo "                  HOLD THE SIRI BUTTON AND SPEAK (normal voice, close to the remote)."
echo
rm -f "$WAV"
ffmpeg -hide_banner -loglevel warning -f avfoundation -i ":Siri Remote Mic" \
       -t "$SECONDS_TO_RECORD" -ac 1 -ar 48000 -sample_fmt s16 "$WAV"
FFSTATUS=$?

kill -INT "$ROUTER_PID" 2>/dev/null; wait "$ROUTER_PID" 2>/dev/null

echo
echo "=== router log ==="
cat "$ROUTER_LOG"
echo "=== analysis of $WAV (ffmpeg exit $FFSTATUS) ==="
python3 - "$WAV" "$SECONDS_TO_RECORD" <<'PY'
import struct, sys
path, want = sys.argv[1], float(sys.argv[2])
d = open(path, 'rb').read()
i = d.find(b'data') + 8
s = struct.unpack('<%dh' % ((len(d) - i) // 2), d[i:])
n = len(s)
dur = n / 48000.0
fs = sum(1 for x in s if abs(x) >= 32766)
disc = sum(1 for a, b in zip(s, s[1:]) if abs(b - a) > 8000)
rms = (sum(x * x for x in s) / max(n, 1)) ** 0.5
peak = max((abs(x) for x in s), default=0)
print(f"duration: {dur:.2f}s (requested {want:.0f}s)")
print(f"rms={rms:.0f} peak={peak} full-scale={fs} ({100*fs/max(n,1):.3f}%) big-jumps={disc}")
ok = True
if dur < want - 1: print("WARN: short recording — the delivery chain stopped early"); ok = False
if fs > n * 0.0005: print("WARN: full-scale spikes still present"); ok = False
if disc > dur * 2: print("WARN: many discontinuities — still splicing"); ok = False
print("RESULT:", "LOOKS CLEAN — listen to confirm:  afplay " + path if ok else "STILL BROKEN (see warnings)")
PY
