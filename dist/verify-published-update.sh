#!/bin/bash
# Verify the same signed app-only path consumed by Sparkle after a GitHub Release is published.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
PREVIOUS_VERSION="${2:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]; then
    echo "usage: dist/verify-published-update.sh VERSION [PREVIOUS_VERSION]" >&2
    exit 2
fi
if [ -n "$PREVIOUS_VERSION" ] \
   && ! [[ "$PREVIOUS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]; then
    echo "invalid previous version: $PREVIOUS_VERSION" >&2
    exit 2
fi

. dist/version.sh
EXPECTED_BUILD="$(hypervibe_build_number "$VERSION")"
if [ -n "$PREVIOUS_VERSION" ]; then
    PREVIOUS_BUILD="$(hypervibe_build_number "$PREVIOUS_VERSION")"
    [ "$EXPECTED_BUILD" -gt "$PREVIOUS_BUILD" ] || {
        echo "published build is not newer: $EXPECTED_BUILD <= $PREVIOUS_BUILD" >&2
        exit 1
    }
fi

VERIFY_ROOT="$(/usr/bin/mktemp -d /private/tmp/hypervibe-update-verify.XXXXXX)"
cleanup() {
    /bin/rm -rf "$VERIFY_ROOT"
}
trap cleanup EXIT

APPCAST="$VERIFY_ROOT/appcast.xml"
ARCHIVE_NAME="HyperVibe-$VERSION-macOS-arm64.zip"
ARCHIVE="$VERIFY_ROOT/$ARCHIVE_NAME"
FEED_URL="https://raw.githubusercontent.com/HOLODATA-COM/SiriRemoteForge/main/appcast.xml"
EXPECTED_URL="https://github.com/HOLODATA-COM/SiriRemoteForge/releases/download/v$VERSION/$ARCHIVE_NAME"

/usr/bin/curl --fail --location --silent --show-error \
    -H 'Cache-Control: no-cache' "$FEED_URL?version=$EXPECTED_BUILD" -o "$APPCAST"

SPARKLE_ROOT="$(app/prepare_sparkle.sh)"
SIGN_UPDATE="$SPARKLE_ROOT/bin/sign_update"
"$SIGN_UPDATE" --verify "$APPCAST"
/usr/bin/xmllint --noout "$APPCAST"

ITEM="//*[local-name()='item'][*[local-name()='shortVersionString' and normalize-space(text())='$VERSION']]"
xml_value() {
    /usr/bin/xmllint --xpath "string(($ITEM/$1)[1])" "$APPCAST"
}

ACTUAL_VERSION="$(xml_value "*[local-name()='version']")"
CHANNEL="$(xml_value "*[local-name()='channel']")"
URL="$(xml_value "*[local-name()='enclosure']/@url")"
LENGTH="$(xml_value "*[local-name()='enclosure']/@length")"
SIGNATURE="$(xml_value "*[local-name()='enclosure']/@*[local-name()='edSignature']")"

[ "$ACTUAL_VERSION" = "$EXPECTED_BUILD" ] || {
    echo "unexpected appcast build: $ACTUAL_VERSION" >&2
    exit 1
}
if [[ "$VERSION" == *-* ]]; then
    [ "$CHANNEL" = "beta" ] || { echo "prerelease is not in beta channel" >&2; exit 1; }
else
    [ -z "$CHANNEL" ] || { echo "stable release unexpectedly has a channel" >&2; exit 1; }
fi
[ "$URL" = "$EXPECTED_URL" ] || { echo "unexpected enclosure URL: $URL" >&2; exit 1; }
[[ "$LENGTH" =~ ^[0-9]+$ ]] || { echo "invalid enclosure length: $LENGTH" >&2; exit 1; }
[ -n "$SIGNATURE" ] || { echo "missing enclosure signature" >&2; exit 1; }

/usr/bin/curl --fail --location --silent --show-error --retry 3 "$URL" -o "$ARCHIVE"
ACTUAL_LENGTH="$(/usr/bin/stat -f '%z' "$ARCHIVE")"
[ "$ACTUAL_LENGTH" = "$LENGTH" ] || {
    echo "download length mismatch: $ACTUAL_LENGTH != $LENGTH" >&2
    exit 1
}
"$SIGN_UPDATE" --verify "$ARCHIVE" "$SIGNATURE"

/bin/mkdir -p "$VERIFY_ROOT/extracted"
/usr/bin/ditto -x -k "$ARCHIVE" "$VERIFY_ROOT/extracted"
APP="$VERIFY_ROOT/extracted/HyperVibe.app"
[ -d "$APP" ] || { echo "archive does not contain HyperVibe.app" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
[ "$(/usr/bin/plutil -extract HyperVibeReleaseVersion raw -o - "$APP/Contents/Info.plist")" \
    = "$VERSION" ]
[ "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" \
    = "$EXPECTED_BUILD" ]
[ "$(/usr/bin/plutil -extract SUFeedURL raw -o - "$APP/Contents/Info.plist")" = "$FEED_URL" ]
[ "$(/usr/bin/lipo -archs "$APP/Contents/MacOS/HyperVibe")" = "arm64" ]

echo "PUBLISHED_UPDATE_VERIFY PASS version=$VERSION build=$EXPECTED_BUILD bytes=$ACTUAL_LENGTH"
