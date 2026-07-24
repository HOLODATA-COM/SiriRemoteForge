#!/bin/bash
# package.sh — assemble a double-clickable "HyperVibe Setup.app" that installs the whole system
# on another Apple-silicon Mac. Bundles the CURRENT built artifacts (arm64) — it does NOT rebuild,
# so it never disturbs a live capture pipeline. Build the components first if any are missing.
#
#   Output:  dist/build/HyperVibe Setup.app   and   dist/build/HyperVibe-Setup.zip (send this)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
DIST="$ROOT/dist"
OUT="$DIST/build"
APP="$OUT/HyperVibe Setup.app"

need() { [ -e "$1" ] || { echo "✗ missing: $1"; echo "  build it first (see dist/README.md)"; exit 1; }; }
need "$ROOT/app/HyperVibe.app"
need "$ROOT/mic/driver/SiriRemoteMic.driver"
need "$ROOT/mic/router/srm_router"
need "$ROOT/mic/captured/srm_captured"
need "$ROOT/mic/captured/au.holodata.SiriRemoteMic.captured.plist"

echo "→ arch check"
file "$ROOT/mic/captured/srm_captured" | grep -q arm64 || echo "  ⚠ not arm64 — target Mac must match"

echo "→ assembling payload"
rm -rf "$OUT"; mkdir -p "$OUT/payload"
P="$OUT/payload"
cp -R "$ROOT/app/HyperVibe.app"                                   "$P/"
cp -R "$ROOT/mic/driver/SiriRemoteMic.driver"                    "$P/"
cp    "$ROOT/mic/router/srm_router"                              "$P/"
cp    "$ROOT/mic/captured/srm_captured"                          "$P/"
cp    "$ROOT/mic/captured/au.holodata.SiriRemoteMic.captured.plist" "$P/"
cp    "$DIST/do_install.sh"                                      "$P/"
# Config: bake in THIS user's current bindings (push-to-talk etc.) if present, else the example.
if [ -f "$HOME/.config/siriremote/config.jsonc" ]; then
    cp "$HOME/.config/siriremote/config.jsonc" "$P/config.jsonc"
    echo "  • bundled your current config.jsonc"
else
    cp "$ROOT/examples/config.jsonc" "$P/config.jsonc"
    echo "  • bundled examples/config.jsonc (no personal config found)"
fi

# Optional: bundle THIS Mac's PacketLogger so the target needs no manual download. OPT-IN via
# `SRM_BUNDLE_PACKETLOGGER=1` or `--with-packetlogger`. It is Apple's tool (Additional Tools for
# Xcode) — fine to copy between your OWN machines, but do NOT redistribute it publicly. It is
# Apple-signed + universal, so it installs cleanly on the target.
if [ "${SRM_BUNDLE_PACKETLOGGER:-0}" = "1" ] || [ "${1:-}" = "--with-packetlogger" ]; then
    if [ -d /Applications/PacketLogger.app ]; then
        cp -R /Applications/PacketLogger.app "$P/PacketLogger.app"
        echo "  • bundled PacketLogger.app  ⚠ personal use only — do NOT redistribute publicly"
    else
        echo "  ⚠ --with-packetlogger requested but /Applications/PacketLogger.app not found — skipping"
    fi
fi

echo "→ building installer app"
rm -rf "$APP"
osacompile -o "$APP" "$DIST/installer.applescript"
cp -R "$P" "$APP/Contents/Resources/payload"
/usr/libexec/PlistBuddy -c "Set :CFBundleName HyperVibe Setup" "$APP/Contents/Info.plist" 2>/dev/null || true

# Ad-hoc sign the OUTER app only (NOT --deep: --deep would re-sign the nested HyperVibe.app and
# strip its entitlements). The nested bundles keep their own signatures; they are sealed as data.
echo "→ signing (ad-hoc)"
codesign --force --sign - "$APP"

echo "→ zipping for transfer"
( cd "$OUT" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent "HyperVibe Setup.app" "HyperVibe-Setup.zip" )

echo
echo "✓ app: $APP"
echo "✓ zip: $OUT/HyperVibe-Setup.zip"
echo
echo "On the other Mac: unzip → right-click \"HyperVibe Setup.app\" → Open → Open, then follow the prompts."
