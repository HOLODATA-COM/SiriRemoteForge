#!/bin/bash
#
# Bounded, reversible activation trial for the Siri Remote microphone DEXT.
#
# PRECONDITION (manual, not done here): macOS platform security must already be
# relaxed enough for a self-signed DEXT with restricted DriverKit/HID entitlements
# to load — otherwise AMFI kills the host before main (Code=-413). See the recovery
# runbook. This script does NOT change SIP/AMFI and does NOT reboot.
#
# What it does (all reversible):
#   1. snapshot the current interface-5 owner (AppleEmbeddedBluetoothAudio);
#   2. copy the signed host bundle to /Applications (parent-bundle-location rule);
#   3. stop the single normal HyperVibe instance and verify its HID client is gone;
#   4. launch the installed host with --activate (submits OSSystemExtensionRequest).
#
# After running: approve in System Settings > General > Login Items & Extensions >
# Drivers if prompted, then run ./check-ownership.sh to verify the DEXT actually
# displaced Apple's driver, then hold the Siri button while watching the DEXT log.
# When finished, run ./restore-normal.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILT_HOST="$REPO_ROOT/.build/driverkit/Products/Debug/SiriRemoteMicHost.app"
INSTALLED_HOST="/Applications/SiriRemoteMicHost.app"
HYPERVIBE="$REPO_ROOT/app/HyperVibe.app"

echo "== 0. baseline: current interface-5 owner =="
ioreg -c AppleEmbeddedBluetoothAudio -r -d 1 2>/dev/null \
  | grep -E '\+-o AppleEmbeddedBluetoothAudio|"IOProbeScore"|"ProductID"' || \
  echo "  (no AppleEmbeddedBluetoothAudio instance found — is the remote connected?)"

echo
echo "== SIP status (informational; relaxation is a separate manual step) =="
csrutil status 2>&1 || true

echo
echo "== 1. install signed host to /Applications =="
test -d "$BUILT_HOST" || { echo "ERROR: build+sign the host first (build-host.sh / sign-host-development.sh)"; exit 1; }
rm -rf -- "$INSTALLED_HOST"
ditto "$BUILT_HOST" "$INSTALLED_HOST"
codesign --verify --deep --strict "$INSTALLED_HOST" && echo "  installed + signature OK: $INSTALLED_HOST"

echo
echo "== 2. stop the single normal HyperVibe instance (trial invariant) =="
if pgrep -f "HyperVibe.app/Contents/MacOS/HyperVibe" >/dev/null; then
  pkill -f "HyperVibe.app/Contents/MacOS/HyperVibe" || true
  sleep 1
fi
if pgrep -f "HyperVibe.app/Contents/MacOS/HyperVibe" >/dev/null; then
  echo "  WARNING: HyperVibe still running; stop it before trusting the trial."
else
  echo "  HyperVibe stopped."
fi

echo
echo "== 3. submit activation from the installed host =="
open "$INSTALLED_HOST" --args --activate

cat <<'NEXT'

Next (manual):
  - If macOS asks, approve in System Settings > General >
    Login Items & Extensions > Drivers, then re-run this only if needed.
  - Verify the DEXT actually took over interface 5:
        ./check-ownership.sh
  - Watch the DEXT log while holding the Siri button (separate terminal):
        log stream --style compact --predicate 'eventMessage CONTAINS "SiriRemoteMicDriver"'
  - When done, restore the normal setup:
        ./restore-normal.sh
NEXT
