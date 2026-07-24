#!/bin/bash
#
# Report everything macOS will tell us about the paired 3rd-gen Siri Remote.
#
# Works in the NORMAL paired state — no unpairing, no CoreBluetooth, no elevated
# privileges. The microphone is not obtainable on macOS (see
# docs/mic-reverse-engineering.md), but battery, firmware, signal, address and the
# full HID interface map all are.
#
# Usage: ./remote-info.sh          human-readable report
#        ./remote-info.sh --battery   just the battery percentage (for scripting)

set -uo pipefail

SERIAL="${SIRIREMOTE_SERIAL:-C08RQGMC2330}"
PRODUCT_ID=789   # 0x0315

bt_block() {
    system_profiler SPBluetoothDataType 2>/dev/null \
        | awk -v s="$SERIAL:" '$0 ~ s {f=1; next} f && /^ *[A-Za-z0-9_-]+:$/ {exit} f'
}

bt_field() {
    # Print everything after the first "<key>: " — must not split on ':' because
    # values such as the Bluetooth address contain colons.
    bt_block | awk -v k="$1" '$0 ~ "^ *" k ": *" { sub("^ *" k ": *", ""); print; exit }'
}

if [ "${1:-}" = "--battery" ]; then
    bt_field "Battery Level"
    exit 0
fi

echo "=========== Siri Remote (3rd gen) ==========="
echo "  serial / name    : $SERIAL"

BATT=$(bt_field "Battery Level")
FW=$(bt_field "Firmware Version")
RSSI=$(bt_field "RSSI")
ADDR=$(bt_field "Address")
VID=$(bt_field "Vendor ID")
PID=$(bt_field "Product ID")

if [ -n "${BATT:-}" ]; then
    echo "  battery          : ${BATT}"
else
    echo "  battery          : (unavailable — remote not connected?)"
fi
[ -n "${FW:-}"   ] && echo "  firmware         : ${FW}"
[ -n "${RSSI:-}" ] && echo "  signal (RSSI)    : ${RSSI} dBm"
[ -n "${ADDR:-}" ] && echo "  bluetooth address: ${ADDR}"
[ -n "${VID:-}"  ] && echo "  vendor / product : ${VID} / ${PID}"

echo
echo "  HID interfaces exposed by macOS:"
ioreg -a -w0 -l -c IOHIDInterface 2>/dev/null > /tmp/.remote_hid.plist
python3 - "$PRODUCT_ID" <<'PY'
import plistlib, sys
pid = int(sys.argv[1])
rows = set()
def walk(n):
    if isinstance(n, dict):
        # Only take nodes that carry a Transport: the others are duplicate
        # parent/child entries without report-size detail.
        if (n.get('ProductID') == pid and n.get('PrimaryUsage') is not None
                and n.get('Transport')):
            rows.add((n.get('Transport'), n.get('PrimaryUsagePage'), n.get('PrimaryUsage'),
                      n.get('MaxInputReportSize'), n.get('MaxFeatureReportSize')))
        for v in n.values(): walk(v)
    elif isinstance(n, list):
        for v in n: walk(v)
try:
    walk(plistlib.load(open('/tmp/.remote_hid.plist','rb')))
except Exception as e:
    print("    (could not read IORegistry:", e, ")"); raise SystemExit

NAMES = {(12,1):'consumer control', (12,4):'audio (mic channel)', (12,265):'consumer 0x109',
         (13,1):'digitizer / trackpad', (32,66):'sensor 0x42', (32,224):'sensor 0xE0',
         (65280,11):'Apple device management'}
if not rows:
    print("    (none — remote not connected)")
for t, up, u, mi, mf in sorted(rows, key=lambda r: (str(r[0]), r[1] or 0, r[2] or 0)):
    if up is None or u is None: continue
    label = NAMES.get((up, u), '')
    print(f"    {str(t):<24} usagePage=0x{up:04X} usage=0x{u:02X}  "
          f"maxIn={str(mi):<5} maxFeat={str(mf):<5} {label}")
PY
rm -f /tmp/.remote_hid.plist
echo "============================================="
