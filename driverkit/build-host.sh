#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$REPOSITORY_ROOT/.build/driverkit"
APP_BUNDLE="$BUILD_ROOT/Products/Debug/SiriRemoteMicHost.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/SiriRemoteMicHost"
EMBEDDED_DEXT_DIRECTORY="$APP_BUNDLE/Contents/Library/SystemExtensions"
BUILT_DEXT="$BUILD_ROOT/Products/Debug-driverkit/com.hypervibe.SiriRemoteMicDriver.dext"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

"$SCRIPT_DIR/build-driver.sh"

rm -rf -- "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$EMBEDDED_DEXT_DIRECTORY"
mkdir -p "$BUILD_ROOT/ModuleCache.noindex/host"

xcrun --sdk macosx swiftc \
    -sdk "$MACOS_SDK" \
    -target arm64-apple-macosx13.0 \
    -module-cache-path "$BUILD_ROOT/ModuleCache.noindex/host" \
    -o "$APP_EXECUTABLE" \
    "$SCRIPT_DIR/Host/main.swift" \
    -framework AppKit \
    -framework SystemExtensions

cp "$SCRIPT_DIR/Host/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
ditto "$BUILT_DEXT" "$EMBEDDED_DEXT_DIRECTORY/com.hypervibe.SiriRemoteMicDriver.dext"

test -x "$APP_EXECUTABLE"
test -f "$EMBEDDED_DEXT_DIRECTORY/com.hypervibe.SiriRemoteMicDriver.dext/Info.plist"

echo "Built unsigned host: $APP_BUNDLE"
echo "No system-extension request was submitted."
