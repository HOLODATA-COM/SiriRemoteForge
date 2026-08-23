#!/bin/bash

# Creates a proper macOS app bundle structure

set -e

APP_NAME="HyperVibe"
APP_BUNDLE="${HYPERVIBE_APP_BUNDLE_PATH:-${APP_NAME}.app}"
BINARY_PATH="${HYPERVIBE_BINARY_PATH:-$APP_NAME}"
APP_VERSION="${HYPERVIBE_VERSION:-1.0.0}"
BUILD_NUMBER="${HYPERVIBE_BUILD_NUMBER:-1}"
SIGN_MODE="${HYPERVIBE_SIGN_MODE:-stable}"

if ! [[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "Error: HYPERVIBE_VERSION must be numeric (for example 0.1.0), got: $APP_VERSION"
    exit 1
fi
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Error: HYPERVIBE_BUILD_NUMBER must be an integer, got: $BUILD_NUMBER"
    exit 1
fi

if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: $BINARY_PATH executable not found."
    echo "Please build first with: ./build.sh"
    exit 1
fi

echo "Creating app bundle: $APP_BUNDLE"

# Create bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy executable
cp "$BINARY_PATH" "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"

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
	<string>$BUILD_NUMBER</string>
	<key>CFBundleShortVersionString</key>
	<string>$APP_VERSION</string>
	<key>CFBundleIconFile</key>
	<string>HyperVibe</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 HyperVibe Contributors</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<!-- Login Items and a manual reopen must converge on the same running process. Without this,
	     LaunchServices may create a second LSUIElement instance, duplicating HID/media handling. -->
	<key>LSMultipleInstancesProhibited</key>
	<true/>
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

# Keep the license with every binary distribution, including the app-only Release asset.
if [ -f "../LICENSE" ]; then
    cp "../LICENSE" "${APP_BUNDLE}/Contents/Resources/LICENSE.txt"
fi
if [ -f "../NOTICE" ]; then
    cp "../NOTICE" "${APP_BUNDLE}/Contents/Resources/NOTICE.txt"
fi

# Make executable
chmod +x "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"

# Sign WITHOUT hardened runtime. The app loads the private MultitouchSupport framework and
# takes its touch callback; under the hardened runtime that callback trips code-signing enforcement
# and the process is SIGKILLed with "Code Signature Invalid" the instant you touch the trackpad.
# (The raw dev binary works precisely because it has no hardened runtime.) Entitlements are embedded
# but only matter under hardened runtime, so they're harmless here.
if [ -f "HyperVibe.entitlements" ]; then
    # Development builds MUST use the stable self-signed identity so TCC grants (Accessibility /
    # Input Monitoring) survive rebuilds. The keychain must be unlocked before find-identity can see
    # its certificate; checking first silently fell back to ad-hoc and invalidated existing grants.
    # Ad-hoc signing remains available only as an explicit release-build choice.
    SIGN_ID="siriRemote Local Signing"
    SIGN_KC="$HOME/Library/Keychains/siriremote-signing.keychain-db"
    if [ "$SIGN_MODE" = "stable" ]; then
        if [ ! -f "$SIGN_KC" ]; then
            echo "Error: stable signing keychain not found: $SIGN_KC"
            echo "Refusing to ad-hoc sign a development build because that would reset macOS permissions."
            exit 1
        fi
        if ! security unlock-keychain -p siriremote-local "$SIGN_KC"; then
            echo "Error: could not unlock the stable signing keychain."
            echo "Refusing to ad-hoc sign a development build because that would reset macOS permissions."
            exit 1
        fi
        # `security find-identity -p codesigning` reports this intentionally self-signed local
        # certificate as "0 valid identities" on some macOS releases even though its private key
        # is present and `codesign` can use it. Check the named certificate here; the codesign call
        # and strict verification below are the authoritative private-key/validity tests.
        if ! security find-certificate -c "$SIGN_ID" "$SIGN_KC" >/dev/null 2>&1; then
            echo "Error: stable signing certificate '$SIGN_ID' is unavailable."
            echo "Refusing to ad-hoc sign a development build because that would reset macOS permissions."
            exit 1
        fi
        echo "Signing with stable local identity ($SIGN_ID)..."
        if ! codesign --force --entitlements "HyperVibe.entitlements" \
            --sign "$SIGN_ID" --keychain "$SIGN_KC" "${APP_BUNDLE}"; then
            echo "Error: stable signing failed. The existing installed App was not touched."
            exit 1
        fi
    elif [ "$SIGN_MODE" = "adhoc" ]; then
        echo "Ad-hoc signing (explicit public/release build)..."
        codesign --force --entitlements "HyperVibe.entitlements" --sign - "${APP_BUNDLE}"
    else
        echo "Error: HYPERVIBE_SIGN_MODE must be 'stable' or 'adhoc', got: $SIGN_MODE"
        exit 1
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
