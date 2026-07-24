#!/bin/bash
#
# live_monitor.sh — clean, low-latency live "ear monitor" for the Siri Remote microphone.
#
# Architecture (why this is the clean path):
#   PacketLogger's live stdout stream (`convert -s`) DROPS ~half the voice frames when the
#   reader drains slower than capture — a pipe backs up and PacketLogger discards HCI. So we do
#   NOT use a pipe. We capture to a FILE with the tool's lossless mode (`convert -o FILE.pklg`),
#   which never exerts backpressure, and TAIL that file, reassembling the ACL fragments in the
#   router. (The shipping app RemotePilot uses the same file-backed-tail shape — it redirects
#   `convert -s -f nhdr > tempfile` and tails it; we use the strictly-safer binary capture.)
#
# Two processes: capture runs as root (HCI needs it); the router runs as YOU (for clean audio).
#
# Prerequisite: Bluetooth HCI debug logging must be enabled (the com.apple.MobileBluetooth.debug
# HCITraces defaults the spike/RemotePilot set). If capture produces nothing, that is why.
#
# Usage:   ./live_monitor.sh [jitter_buffer_ms]      # default 100 ms
#          Hold the Siri button and speak — you hear yourself. Ctrl-C to stop.
#
set -uo pipefail
cd "$(dirname "$0")"

PL="/Applications/PacketLogger.app/Contents/Resources/packetlogger"
[ -x "$PL" ] || PL="/Volumes/Additional Tools/Hardware/PacketLogger.app/Contents/Resources/packetlogger"
if [ ! -x "$PL" ]; then echo "live_monitor: packetlogger not found" >&2; exit 1; fi
if [ ! -x ./srm_router ]; then echo "live_monitor: run ./build.sh first" >&2; exit 1; fi

BUFFER_MS="${1:-100}"
PKLG="/tmp/srm_live_$$.pklg"
rm -f "$PKLG"

cleanup() {
    echo
    echo "live_monitor: stopping capture…"
    [ -n "${CAP_PID:-}" ] && sudo kill "$CAP_PID" 2>/dev/null
    sudo pkill -f "packetlogger convert -o $PKLG" 2>/dev/null
    rm -f "$PKLG"
}
trap cleanup EXIT INT TERM

echo "live_monitor: HCI capture needs sudo — enter your password if prompted."
sudo -v || { echo "live_monitor: sudo required for live capture" >&2; exit 1; }

echo "live_monitor: starting lossless capture → $PKLG"
sudo "$PL" convert -o "$PKLG" &
CAP_PID=$!

# Wait for the capture to create the file and write its header.
for _ in $(seq 1 100); do [ -s "$PKLG" ] && break; sleep 0.05; done
if [ ! -s "$PKLG" ]; then
    echo "live_monitor: capture did not start writing." >&2
    echo "  Enable Bluetooth HCI debug logging first (com.apple.MobileBluetooth.debug HCITraces)." >&2
    exit 1
fi

echo
echo "live_monitor: READY — hold the Siri button and speak. You should hear yourself."
echo "live_monitor: jitter buffer ${BUFFER_MS} ms. Press Ctrl-C to stop."
echo
# Router runs as YOU (not root) so AVAudioEngine plays to your normal default output.
./srm_router --pklg "$PKLG" --monitor --no-ring --monitor-buffer-ms "$BUFFER_MS"
