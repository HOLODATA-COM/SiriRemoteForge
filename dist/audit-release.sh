#!/bin/bash
# Fail closed unless versioned Release archives are portable, internally consistent, and public-safe.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
VERSION="${1:-}"

if [ -z "$VERSION" ]; then
    echo "usage: dist/audit-release.sh VERSION" >&2
    exit 2
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "invalid release version: $VERSION" >&2
    exit 2
fi

APP_VERSION="${VERSION%%-*}"
BUILD_NUMBER="${HYPERVIBE_BUILD_NUMBER:-1}"
OUT="$ROOT/dist/build/$VERSION"
APP_ZIP="$OUT/HyperVibe-$VERSION-macOS-arm64.zip"
FULL_ZIP="$OUT/HyperVibe-Full-Setup-$VERSION-arm64.zip"
CHECKSUMS="$OUT/SHA256SUMS.txt"

for required in "$APP_ZIP" "$FULL_ZIP" "$CHECKSUMS"; do
    [ -f "$required" ] || { echo "missing Release asset: $required" >&2; exit 1; }
done

AUDIT_DIR="$(/usr/bin/mktemp -d /private/tmp/hypervibe-release-audit.XXXXXX)"
cleanup() {
    /bin/rm -rf "$AUDIT_DIR"
}
trap cleanup EXIT

echo "→ auditing archive checksums"
(cd "$OUT" && /usr/bin/shasum -a 256 -c "$(basename "$CHECKSUMS")")

/bin/mkdir -p "$AUDIT_DIR/app-only" "$AUDIT_DIR/full"
/usr/bin/ditto -x -k "$APP_ZIP" "$AUDIT_DIR/app-only"
/usr/bin/ditto -x -k "$FULL_ZIP" "$AUDIT_DIR/full"

APP="$AUDIT_DIR/app-only/HyperVibe.app"
SETUP="$AUDIT_DIR/full/HyperVibe Setup.app"
PAYLOAD="$SETUP/Contents/Resources/payload"
UNINSTALL="$PAYLOAD/HyperVibe Uninstall.app"

for required in "$APP" "$SETUP" "$UNINSTALL" "$PAYLOAD/PAYLOAD-SHA256SUMS.txt"; do
    [ -e "$required" ] || { echo "missing archive member: $required" >&2; exit 1; }
done

echo "→ auditing signatures and payload seal"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$SETUP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$UNINSTALL"
(cd "$PAYLOAD" && /usr/bin/shasum -a 256 -c PAYLOAD-SHA256SUMS.txt >/dev/null)

echo "→ auditing versions, architecture, and runtime links"
[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" \
    = "$APP_VERSION" ]
[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$SETUP/Contents/Info.plist")" \
    = "$APP_VERSION" ]
[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$UNINSTALL/Contents/Info.plist")" \
    = "$APP_VERSION" ]
for bundle in "$APP" "$SETUP" "$UNINSTALL" "$PAYLOAD/SiriRemoteMic.driver"; do
    [ "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$bundle/Contents/Info.plist")" \
        = "$BUILD_NUMBER" ] || {
        echo "unexpected bundle build number: $bundle" >&2
        exit 1
    }
done

for binary in "$APP/Contents/MacOS/HyperVibe" "$PAYLOAD/srm_router" "$PAYLOAD/srm_captured" \
    "$PAYLOAD/SiriRemoteMic.driver/Contents/MacOS/SiriRemoteMic"; do
    [ "$(/usr/bin/lipo -archs "$binary")" = "arm64" ] || {
        echo "non-arm64 shipping binary: $binary" >&2
        exit 1
    }
    MINOS="$(/usr/bin/vtool -show-build "$binary" \
        | /usr/bin/awk '/^[[:space:]]*minos / { print $2; exit }')"
    case "$MINOS" in
        13|13.0|13.0.0) ;;
        *)
            echo "unexpected minimum macOS version ($MINOS): $binary" >&2
            exit 1
            ;;
    esac
done
if /usr/bin/otool -L "$PAYLOAD/srm_router" | /usr/bin/grep -Eq '/opt/homebrew|/usr/local'; then
    echo "REFUSED: router has a package-manager runtime dependency" >&2
    exit 1
fi

echo "→ auditing licenses and public-data boundary"
/usr/bin/cmp "$PAYLOAD/config.jsonc" "$ROOT/examples/config.jsonc"
[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
    "$PAYLOAD/SiriRemoteMic.driver/Contents/Info.plist")" = "$APP_VERSION" ]
for required in "$APP/Contents/Resources/LICENSE.txt" "$APP/Contents/Resources/NOTICE.txt" \
    "$PAYLOAD/Legal/GPL-3.0.txt" "$PAYLOAD/Legal/NOTICE.txt" \
    "$PAYLOAD/Legal/BlackHole-LICENSE.txt" "$PAYLOAD/Legal/Opus-LICENSE.txt"; do
    [ -f "$required" ] || { echo "missing distribution notice: $required" >&2; exit 1; }
done
/usr/bin/grep -Fxq "Package mode: public" "$PAYLOAD/BUILD-INFO.txt"
/usr/bin/grep -Fxq "Source commit: $(git rev-parse HEAD)" "$PAYLOAD/BUILD-INFO.txt"
/usr/bin/grep -Fxq "Personal config bundled: no" "$PAYLOAD/BUILD-INFO.txt"
/usr/bin/grep -Fxq "PacketLogger bundled: no" "$PAYLOAD/BUILD-INFO.txt"

if /usr/bin/find "$AUDIT_DIR" \( -iname '*PacketLogger*' -o -iname '*config.author*' \
    -o -iname '*video*' \) -print | /usr/bin/grep -q .; then
    echo "REFUSED: forbidden public artifact name found" >&2
    exit 1
fi
if /usr/bin/grep -R -a -l -E \
    '/Users/[^/]+/|([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}' \
    "$AUDIT_DIR" >/dev/null 2>&1; then
    echo "REFUSED: possible personal path or device identifier embedded" >&2
    exit 1
fi

[ -x "$PAYLOAD/do_install.sh" ]
[ -x "$PAYLOAD/do_uninstall.sh" ]
[ -x "$PAYLOAD/srm_router" ]
[ -x "$PAYLOAD/srm_captured" ]

echo "✓ Release audit passed"
