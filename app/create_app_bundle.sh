#!/bin/bash

# Creates a proper macOS app bundle structure

set -e

APP_NAME="HyperVibe"
APP_BUNDLE="${APP_NAME}.app"

if [ ! -f "$APP_NAME" ]; then
    echo "Error: $APP_NAME executable not found."
    echo "Please build first with: ./build.sh"
    exit 1
fi

BINARY_NAME="$APP_NAME"

echo "Creating app bundle: $APP_BUNDLE"

# Create bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy executable
cp "$BINARY_NAME" "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"

# Generate the app icon if it's missing (it's a build artifact — .icns is git-ignored).
if [ ! -f "HyperVibe.icns" ] && [ -f "tools/make_app_icon.swift" ]; then
    echo "Generating app icon..."
    TMP_ICONSET="$(mktemp -d)/HyperVibe.iconset"
    if swift tools/make_app_icon.swift "$TMP_ICONSET" >/dev/null 2>&1 \
        && iconutil -c icns "$TMP_ICONSET" -o "HyperVibe.icns" 2>/dev/null; then
        echo "App icon generated"
    else
        echo "Icon generation skipped (swift/iconutil unavailable)"
    fi
fi

# Copy icon if it exists
if [ -f "HyperVibe.icns" ]; then
    cp "HyperVibe.icns" "${APP_BUNDLE}/Contents/Resources/HyperVibe.icns"
    echo "Icon added to app bundle"
elif [ -f "SiriRemote.icns" ]; then
    cp "SiriRemote.icns" "${APP_BUNDLE}/Contents/Resources/HyperVibe.icns"
    echo "Icon added to app bundle"
fi

# Copy menu bar icon resources
if [ -d "Resources" ]; then
    cp Resources/MenuBarIcon*.png "${APP_BUNDLE}/Contents/Resources/" 2>/dev/null || true
    echo "Menu bar icons added to app bundle"
fi

# Create proper Info.plist with all required keys
echo "Creating Info.plist..."
cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>com.hypervibe.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleIconFile</key>
	<string>HyperVibe</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 HyperVibe Contributors</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>HyperVibe needs Bluetooth access to connect to your Siri Remote trackpad.</string>
	<key>NSBluetoothPeripheralUsageDescription</key>
	<string>HyperVibe needs Bluetooth access to connect to your Siri Remote trackpad.</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>siriRemote sends AppleScript to apps you bind (e.g. play/pause Apple Music) when the remote's buttons are pressed.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>HyperVibe plays your Mac's built-in microphone through the "Siri Remote Mic" device whenever the remote isn't transmitting voice, so apps using that device always hear live audio.</string>
</dict>
</plist>
EOF

# Make executable
chmod +x "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"

# Ad-hoc sign WITHOUT hardened runtime. The app loads the private MultitouchSupport framework and
# takes its touch callback; under the hardened runtime that callback trips code-signing enforcement
# and the process is SIGKILLed with "Code Signature Invalid" the instant you touch the trackpad.
# (The raw dev binary works precisely because it has no hardened runtime.) Ad-hoc `--sign -` still
# gives a stable identity for TCC (Accessibility / Input Monitoring). Entitlements are embedded but
# only matter under hardened runtime, so they're harmless here.
if [ -f "HyperVibe.entitlements" ]; then
    # Prefer a STABLE self-signed identity ("siriRemote Local Signing") so the app's TCC grants
    # (Accessibility / Input Monitoring) survive rebuilds — ad-hoc's cdhash changes every build and
    # macOS treats each build as a new app, forcing re-approval. Fall back to ad-hoc if absent.
    SIGN_ID="siriRemote Local Signing"
    SIGN_KC="$HOME/Library/Keychains/siriremote-signing.keychain-db"
    if [ -f "$SIGN_KC" ] && security find-identity -p codesigning "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_ID"; then
        echo "Signing with stable local identity ($SIGN_ID)..."
        security unlock-keychain -p siriremote-local "$SIGN_KC" 2>/dev/null || true
        codesign --force --entitlements "HyperVibe.entitlements" \
            --sign "$SIGN_ID" --keychain "$SIGN_KC" "${APP_BUNDLE}"
    else
        echo "Ad-hoc signing (no stable identity found; TCC will re-prompt on each rebuild)..."
        codesign --force --entitlements "HyperVibe.entitlements" --sign - "${APP_BUNDLE}"
    fi
    codesign -dvv "${APP_BUNDLE}" 2>&1 | grep -E "(Authority|flags|Identifier)" || true
fi

echo ""
echo "✓ App bundle created: $APP_BUNDLE"
echo ""
echo "You can now:"
echo "  1. Double-click $APP_BUNDLE to run it"
echo "  2. Or run: open $APP_BUNDLE"
echo ""
echo "Note: You'll need to grant Accessibility permissions in:"
echo "  System Settings → Privacy & Security → Accessibility"
