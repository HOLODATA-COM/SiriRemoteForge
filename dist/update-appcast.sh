#!/bin/bash
# Insert one audited app-only archive into the appropriate channel and sign the whole feed.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: dist/update-appcast.sh VERSION" >&2
    exit 2
fi
. dist/version.sh
BUILD_NUMBER="$(hypervibe_build_number "$VERSION")"
ARCHIVE="dist/build/$VERSION/HyperVibe-$VERSION-macOS-arm64.zip"
NOTES="dist/release-notes-v$VERSION.md"
APPCAST="$PWD/appcast.xml"

for required in "$ARCHIVE" "$NOTES" "$APPCAST"; do
    [ -f "$required" ] || { echo "missing appcast input: $required" >&2; exit 1; }
done

SPARKLE_ROOT="$(app/prepare_sparkle.sh)"
SIGN_UPDATE="$SPARKLE_ROOT/bin/sign_update"
SIGN_KEY_ARGS=()
if [ -n "${HYPERVIBE_SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
    [ -f "$HYPERVIBE_SPARKLE_PRIVATE_KEY_FILE" ] || {
        echo "Sparkle private-key file not found" >&2
        exit 1
    }
    SIGN_KEY_ARGS=(--ed-key-file "$HYPERVIBE_SPARKLE_PRIVATE_KEY_FILE")
fi
SIGNATURE="$("$SIGN_UPDATE" "${SIGN_KEY_ARGS[@]}" -p "$ARCHIVE")"
[ -n "$SIGNATURE" ] || { echo "Sparkle archive signing returned an empty signature" >&2; exit 1; }
LENGTH="$(/usr/bin/stat -f '%z' "$ARCHIVE")"
CHANNEL="stable"
if [[ "$VERSION" == *-* ]]; then CHANNEL="beta"; fi
PUB_DATE="$(LC_ALL=C /bin/date -R)"

/usr/bin/xcrun swift dist/tools/update_appcast.swift \
    "$APPCAST" "$VERSION" "$BUILD_NUMBER" "$(basename "$ARCHIVE")" \
    "$SIGNATURE" "$LENGTH" "$NOTES" "$CHANNEL" "$PUB_DATE"
"$SIGN_UPDATE" "${SIGN_KEY_ARGS[@]}" "$APPCAST" --disable-signing-warning
"$SIGN_UPDATE" "${SIGN_KEY_ARGS[@]}" --verify "$APPCAST"
/usr/bin/xmllint --noout "$APPCAST"
echo "✓ signed appcast updated ($CHANNEL, $VERSION, build $BUILD_NUMBER)"
