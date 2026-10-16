#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Require an explicit, persistent identity. Never silently substitute ad-hoc signing.
: "${APPLE_SIGNING_IDENTITY:?Set APPLE_SIGNING_IDENTITY to your stable local or Developer ID identity}"
if [ "$APPLE_SIGNING_IDENTITY" = "-" ]; then
    echo "Refusing an ad-hoc local development package." >&2
    exit 1
fi
npm run tauri -- build --bundles app
VOICEINK_BUNDLE="$PWD/src-tauri/target/release/bundle/macos/VoiceInk.app"
codesign --verify --deep --strict --verbose=2 "$VOICEINK_BUNDLE"
if [ -n "${VOICEINK_EXPECTED_CERT_SHA1:-}" ]; then
    codesign --verify --strict -R="identifier \"com.holodata.voiceink\" and certificate leaf = H\"$VOICEINK_EXPECTED_CERT_SHA1\"" "$VOICEINK_BUNDLE"
fi

VOICEINK_VERSION="$(node -p 'JSON.parse(require("fs").readFileSync("package.json","utf8")).version')"
VOICEINK_ARCH="$(uname -m)"
VOICEINK_STAGE="$(mktemp -d /private/tmp/voiceink-package.XXXXXX)"
mkdir -p artifacts
ditto "$VOICEINK_BUNDLE" "$VOICEINK_STAGE/VoiceInk.app"
ln -s /Applications "$VOICEINK_STAGE/Applications"
VOICEINK_DMG="$PWD/artifacts/VoiceInk_${VOICEINK_VERSION}_macos-${VOICEINK_ARCH}.dmg"
# A plain read-only drag-to-install DMG avoids controlling Finder or requesting Automation access.
hdiutil create -volname VoiceInk -srcfolder "$VOICEINK_STAGE" -format UDZO -ov "$VOICEINK_DMG"
codesign --force --sign "$APPLE_SIGNING_IDENTITY" "$VOICEINK_DMG"
codesign --verify --strict --verbose=2 "$VOICEINK_DMG"
hdiutil verify "$VOICEINK_DMG"
ditto -c -k --sequesterRsrc --keepParent "$VOICEINK_BUNDLE" "$PWD/artifacts/VoiceInk_${VOICEINK_VERSION}_macos-${VOICEINK_ARCH}.zip"
shasum -a 256 "$VOICEINK_DMG" "$PWD/artifacts/VoiceInk_${VOICEINK_VERSION}_macos-${VOICEINK_ARCH}.zip"
echo "Verified packages are in $PWD/artifacts; staging copy retained at $VOICEINK_STAGE."
