#!/bin/bash

set -euo pipefail

if [ "$#" -ne 1 ] && [ "$#" -ne 3 ]; then
    echo "usage: $0 'exact identity string from security find-identity'" >&2
    echo "   or: $0 'identity' HOST_PROFILE DEXT_PROFILE" >&2
    exit 64
fi

SIGNING_IDENTITY="$1"
HOST_PROFILE="${2:-}"
DEXT_PROFILE="${3:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$REPOSITORY_ROOT/.build/driverkit/Products/Debug/SiriRemoteMicHost.app"
EMBEDDED_DEXT="$APP_BUNDLE/Contents/Library/SystemExtensions/com.hypervibe.SiriRemoteMicDriver.dext"

test -d "$APP_BUNDLE"
test -d "$EMBEDDED_DEXT"

if [ -n "$HOST_PROFILE" ]; then
    test -f "$HOST_PROFILE"
    test -f "$DEXT_PROFILE"
    security cms -D -i "$HOST_PROFILE" >/dev/null
    security cms -D -i "$DEXT_PROFILE" >/dev/null
    cp "$HOST_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
    cp "$DEXT_PROFILE" "$EMBEDDED_DEXT/embedded.provisionprofile"
    echo "Embedded the supplied host and DEXT provisioning profiles."
else
    echo "No provisioning profiles supplied; this signature is for structural validation only."
fi

codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp=none \
    --entitlements "$SCRIPT_DIR/SiriRemoteMicDriver/SiriRemoteMicDriver.entitlements" \
    "$EMBEDDED_DEXT"

codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp=none \
    --entitlements "$SCRIPT_DIR/Host/SiriRemoteMicHost.entitlements" \
    "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
echo "Development-signed host: $APP_BUNDLE"
echo "Signing and profile embedding do not install or activate the system extension."
