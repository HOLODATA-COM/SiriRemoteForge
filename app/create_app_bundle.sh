#!/bin/bash

# Creates a proper macOS app bundle structure

set -e

APP_NAME="HyperVibe"
APP_BUNDLE="${HYPERVIBE_APP_BUNDLE_PATH:-${APP_NAME}.app}"
BINARY_PATH="${HYPERVIBE_BINARY_PATH:-$APP_NAME}"
APP_VERSION="${HYPERVIBE_VERSION:-1.0.0}"
BUILD_NUMBER="${HYPERVIBE_BUILD_NUMBER:-1}"
RELEASE_VERSION="${HYPERVIBE_RELEASE_VERSION:-${APP_VERSION}-local.${BUILD_NUMBER}}"
SIGN_MODE="${HYPERVIBE_SIGN_MODE:-stable}"
SPARKLE_ROOT="$(./prepare_sparkle.sh)"

if ! [[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "Error: HYPERVIBE_VERSION must be numeric (for example 0.1.0), got: $APP_VERSION"
    exit 1
fi
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Error: HYPERVIBE_BUILD_NUMBER must be an integer, got: $BUILD_NUMBER"
    exit 1
fi
if ! [[ "$RELEASE_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.-]*$ ]]; then
    echo "Error: invalid HYPERVIBE_RELEASE_VERSION: $RELEASE_VERSION"
    exit 1
fi

if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: $BINARY_PATH executable not found."
    echo "Please build first with: ./build.sh"
    exit 1
fi
if [ ! -f "HyperVibeCredentialBroker" ]; then
    echo "Error: HyperVibeCredentialBroker executable not found."
    echo "Please build first with: ./build.sh"
    exit 1
fi

echo "Creating app bundle: $APP_BUNDLE"

# Create bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
mkdir -p "${APP_BUNDLE}/Contents/XPCServices/HyperVibeCredentialBroker.xpc/Contents/MacOS"

# Copy executable
cp "$BINARY_PATH" "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"
cp "HyperVibeCredentialBroker" \
    "${APP_BUNDLE}/Contents/XPCServices/HyperVibeCredentialBroker.xpc/Contents/MacOS/HyperVibeCredentialBroker"
/usr/bin/ditto "$SPARKLE_ROOT/Sparkle.framework" \
    "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
/bin/cp "$SPARKLE_ROOT/LICENSE" "${APP_BUNDLE}/Contents/Resources/Sparkle-LICENSE.txt"

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

# Copy every authored app resource, including nested Voice sounds and their license. `ditto`
# preserves the directory structure and merges with generated icons/licenses already copied above.
if [ -d "Resources" ]; then
    /usr/bin/ditto "Resources" "${APP_BUNDLE}/Contents/Resources"
    for voice_asset in VoiceToggleOn.mp3 VoiceToggleOff.mp3 UI-SFX-LICENSE.txt; do
        if [ ! -f "${APP_BUNDLE}/Contents/Resources/Sounds/${voice_asset}" ]; then
            echo "Error: required Voice feedback resource is missing: ${voice_asset}"
            exit 1
        fi
    done
    echo "App resources added to app bundle"
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
	<key>HyperVibeReleaseVersion</key>
	<string>$RELEASE_VERSION</string>
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
	<string>HyperVibe uses your selected microphone for push-to-talk dictation, transcription, and its live waveform.</string>
	<!-- Sparkle update policy. Runtime choices are mirrored from config.jsonc; these values provide
	     secure first-launch defaults before that config has been migrated by the GUI. -->
	<key>SUFeedURL</key>
	<string>https://raw.githubusercontent.com/HOLODATA-COM/SiriRemoteForge/main/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>soFRqtCkorMRWAPsLRxn3ZE7vaihfpjYFH+4kXmc/Hk=</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>SUAllowsAutomaticUpdates</key>
	<true/>
	<key>SUAutomaticallyUpdate</key>
	<true/>
	<key>SUScheduledCheckInterval</key>
	<integer>86400</integer>
	<key>SUVerifyUpdateBeforeExtraction</key>
	<true/>
</dict>
</plist>
EOF

# Keep this embedded service byte-for-byte and metadata-stable across UI releases. The login
# keychain grants its CDHash access once, while the broker mutually authenticates the containing
# App by code-signing requirement before accepting any XPC message.
cat > "${APP_BUNDLE}/Contents/XPCServices/HyperVibeCredentialBroker.xpc/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>HyperVibeCredentialBroker</string>
	<key>CFBundleIdentifier</key>
	<string>com.hypervibe.app.CredentialBroker</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>HyperVibeCredentialBroker</string>
	<key>CFBundlePackageType</key>
	<string>XPC!</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>XPCService</key>
	<dict>
		<key>ServiceType</key>
		<string>Application</string>
	</dict>
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
chmod +x "${APP_BUNDLE}/Contents/XPCServices/HyperVibeCredentialBroker.xpc/Contents/MacOS/HyperVibeCredentialBroker"

# Sign WITHOUT hardened runtime on the outer app. The app loads the private MultitouchSupport framework and
# takes its touch callback; under the hardened runtime that callback trips code-signing enforcement
# and the process is SIGKILLed with "Code Signature Invalid" the instant you touch the trackpad.
# (The raw dev binary works precisely because it has no hardened runtime.) Entitlements are embedded
# but only matter under hardened runtime, so they're harmless here.
[ -f "HyperVibe.entitlements" ] || { echo "Error: HyperVibe.entitlements not found"; exit 1; }

# Development builds MUST use the stable self-signed identity so TCC grants (Accessibility /
# Input Monitoring) survive rebuilds. Ad-hoc signing remains available only as an explicit public
# release-build choice. There is deliberately no automatic fallback between the two modes.
SIGN_ID="siriRemote Local Signing"
SIGN_KC="$HOME/Library/Keychains/siriremote-signing.keychain-db"
CODESIGN_KEYCHAIN_ARGS=()
if [ "$SIGN_MODE" = "stable" ]; then
    if [ ! -f "$SIGN_KC" ]; then
        echo "Error: stable signing keychain not found: $SIGN_KC"
        echo "Refusing to ad-hoc sign a development build because that would reset macOS permissions."
        exit 1
    fi
    if ! security find-certificate -c "$SIGN_ID" "$SIGN_KC" >/dev/null 2>&1; then
        echo "Error: stable signing certificate '$SIGN_ID' is unavailable."
        echo "Refusing to ad-hoc sign a development build because that would reset macOS permissions."
        exit 1
    fi
    # Never put a keychain password in argv: process inspection and build logs must not expose it.
    # Unlock the dedicated keychain through Keychain Access / Security.framework's native secure
    # prompt before a non-interactive build. `security find-identity` incorrectly reports zero for
    # this self-signed identity on current macOS even when its private key is usable, so the named
    # certificate check above plus the real `codesign` operations below are the authoritative gate.
    CODESIGN_KEYCHAIN_ARGS=(--keychain "$SIGN_KC")
    echo "Signing with stable local identity ($SIGN_ID)..."
elif [ "$SIGN_MODE" = "adhoc" ]; then
    SIGN_ID="-"
    echo "Ad-hoc signing (explicit public/release build)..."
else
    echo "Error: HYPERVIBE_SIGN_MODE must be 'stable' or 'adhoc', got: $SIGN_MODE"
    exit 1
fi

# Sparkle's helpers retain hardened runtime even though HyperVibe itself cannot use it. Sign from
# the deepest nested code outward; --deep is verification-only and is never used to construct a
# signature because it can hide a malformed framework bundle.
SPARKLE_B="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B"
CREDENTIAL_XPC="${APP_BUNDLE}/Contents/XPCServices/HyperVibeCredentialBroker.xpc"
codesign --force --sign "$SIGN_ID" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    "$CREDENTIAL_XPC"
codesign --force --options runtime --sign "$SIGN_ID" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    "$SPARKLE_B/XPCServices/Installer.xpc"
codesign --force --options runtime --preserve-metadata=entitlements \
    --sign "$SIGN_ID" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    "$SPARKLE_B/XPCServices/Downloader.xpc"
codesign --force --options runtime --sign "$SIGN_ID" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    "$SPARKLE_B/Autoupdate"
codesign --force --options runtime --sign "$SIGN_ID" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    "$SPARKLE_B/Updater.app"
codesign --force --options runtime --sign "$SIGN_ID" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"

if ! codesign --force --entitlements "HyperVibe.entitlements" \
    --sign "$SIGN_ID" "${CODESIGN_KEYCHAIN_ARGS[@]}" "${APP_BUNDLE}"; then
    echo "Error: app signing failed. The existing installed App was not touched."
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
codesign -dvv "${APP_BUNDLE}" 2>&1 | grep -E "(Authority|flags|Identifier)" || true

echo ""
echo "✓ App bundle created: $APP_BUNDLE"
echo ""
echo "You can now:"
echo "  1. Double-click $APP_BUNDLE to run it"
echo "  2. Or run: open $APP_BUNDLE"
echo ""
echo "Note: You'll need to grant Accessibility permissions in:"
echo "  System Settings → Privacy & Security → Accessibility"
