#!/bin/bash
#
# Read-only ownership + activation check for the Siri Remote microphone DEXT.
# Answers: is the extension registered, and did it actually displace Apple's
# AppleEmbeddedBluetoothAudio on the PID-789 / PrimaryUsage-4 (interface 5) node?

set -euo pipefail

echo "== registered system extensions (our DEXT should appear + be enabled) =="
systemextensionsctl list 2>&1 | grep -iE 'SiriRemoteMicDriver|hypervibe' || \
  echo "  (our DEXT not listed — activation not accepted yet)"

echo
echo "== who owns the audio HID node now? =="
echo "-- our DEXT (SiriRemoteMicDriver) instances --"
ioreg -c SiriRemoteMicDriver -r -d 1 2>/dev/null \
  | grep -E '\+-o SiriRemoteMicDriver|"IOProbeScore"|"ProductID"|"PrimaryUsage"' \
  || echo "  (no SiriRemoteMicDriver instance — it has not matched/started)"
echo "-- Apple's AppleEmbeddedBluetoothAudio instances (target being replaced) --"
ioreg -c AppleEmbeddedBluetoothAudio -r -d 1 2>/dev/null \
  | grep -E '\+-o AppleEmbeddedBluetoothAudio|"IOProbeScore"|"ProductID"' \
  || echo "  (no AppleEmbeddedBluetoothAudio instance — displaced, or remote offline)"

echo
echo "== recent DEXT log (activation result + any captured reports) =="
log show --last 5m --style compact \
  --predicate 'eventMessage CONTAINS "SiriRemoteMicDriver"' 2>/dev/null | tail -30 || \
  echo "  (no DEXT log lines in the last 5 minutes)"
