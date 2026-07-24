#!/bin/bash
#
# Restore the normal runtime after a DEXT activation trial:
#   1. request DEXT deactivation (may defer until reboot — that is fine);
#   2. relaunch exactly one normal HyperVibe instance;
#   3. verify Apple's audio service is back and exactly one HyperVibe runs.
#
# This does NOT re-enable SIP/AMFI — that is a separate manual recovery step.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLED_HOST="/Applications/SiriRemoteMicHost.app"
HYPERVIBE="$REPO_ROOT/app/HyperVibe.app"

echo "== 1. request DEXT deactivation =="
if [ -d "$INSTALLED_HOST" ]; then
  open "$INSTALLED_HOST" --args --deactivate
  echo "  submitted --deactivate (result may be 'will complete after reboot')."
else
  echo "  installed host not found; skipping deactivation request."
fi

echo
echo "== 2. relaunch exactly one normal HyperVibe =="
pkill -f "HyperVibe.app/Contents/MacOS/HyperVibe" 2>/dev/null || true
sleep 1
open "$HYPERVIBE"
sleep 2

echo
echo "== 3. verify =="
COUNT="$(pgrep -fc "HyperVibe.app/Contents/MacOS/HyperVibe" || echo 0)"
echo "  HyperVibe instances running: $COUNT (want exactly 1)"
echo "  Apple audio service present?"
ioreg -c AppleEmbeddedBluetoothAudio -r -d 1 2>/dev/null \
  | grep -E '\+-o AppleEmbeddedBluetoothAudio' \
  || echo "    (not yet — may return after reboot / remote reconnect)"
