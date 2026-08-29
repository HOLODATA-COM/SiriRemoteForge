#!/bin/bash
# Assemble public-safe, versioned Release assets from the current built artifacts.
#
# Public mode is the default and cannot include a personal config or PacketLogger:
#   dist/package.sh --version 0.1.0-beta.1
#
# Personal transfer mode is explicit and must never be uploaded:
#   dist/package.sh --personal --with-packetlogger --version local
set -Eeuo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
DIST="$ROOT/dist"
BUILD_ROOT="$DIST/build"
APP_SOURCE="${HYPERVIBE_APP_PATH:-$ROOT/app/HyperVibe.app}"
MODE="public"
VERSION="${HYPERVIBE_RELEASE_VERSION:-dev}"
BUILD_NUMBER="${HYPERVIBE_BUILD_NUMBER:-}"
WITH_PACKETLOGGER=0
CONFIG_SOURCE=""

usage() {
    echo "usage: dist/package.sh [--version VERSION] [--personal [--config PATH] [--with-packetlogger]]"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            VERSION="$2"
            shift 2
            ;;
        --personal)
            MODE="personal"
            shift
            ;;
        --config)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            CONFIG_SOURCE="$2"
            shift 2
            ;;
        --with-packetlogger)
            WITH_PACKETLOGGER=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage
            exit 2
            ;;
    esac
done

if ! [[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.-]*$ ]]; then
    echo "invalid release version: $VERSION" >&2
    exit 2
fi
APP_VERSION="${HYPERVIBE_APP_VERSION:-${VERSION%%-*}}"
if ! [[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    if [ "$MODE" = "personal" ]; then
        APP_VERSION="0.0.0"
    else
        echo "public package version must start with a numeric app version: $VERSION" >&2
        exit 2
    fi
fi
if [ -z "$BUILD_NUMBER" ]; then
    if [ "$MODE" = "public" ]; then
        . "$DIST/version.sh"
        BUILD_NUMBER="$(hypervibe_build_number "$VERSION")"
    else
        BUILD_NUMBER=1
    fi
fi
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "invalid build number: $BUILD_NUMBER" >&2
    exit 2
fi
if [ "$MODE" = "public" ] && { [ -n "$CONFIG_SOURCE" ] || [ "$WITH_PACKETLOGGER" -eq 1 ]; }; then
    echo "REFUSED: public assets cannot include --config or --with-packetlogger" >&2
    exit 2
fi

need() {
    [ -e "$1" ] || {
        echo "missing build artifact: $1" >&2
        echo "run dist/build-release.sh first" >&2
        exit 1
    }
}

need "$APP_SOURCE"
need "$ROOT/mic/driver/SiriRemoteMic.driver"
need "$ROOT/mic/router/srm_router"
need "$ROOT/mic/captured/srm_captured"
need "$ROOT/mic/captured/au.holodata.SiriRemoteMic.captured.plist"

ARCHS="$(/usr/bin/lipo -archs "$APP_SOURCE/Contents/MacOS/HyperVibe")"
case "$ARCHS" in
    arm64) ASSET_ARCH="arm64" ;;
    x86_64) ASSET_ARCH="x86_64" ;;
    *"arm64"*"x86_64"*|*"x86_64"*"arm64"*) ASSET_ARCH="universal" ;;
    *)
        echo "unsupported app architecture list: $ARCHS" >&2
        exit 1
        ;;
esac

OUT="$BUILD_ROOT/$VERSION"
PAYLOAD="$OUT/payload"
SETUP_APP="$OUT/HyperVibe Setup.app"
UNINSTALL_APP="$OUT/HyperVibe Uninstall.app"
APP_ZIP="$OUT/HyperVibe-$VERSION-macOS-$ASSET_ARCH.zip"
FULL_ZIP="$OUT/HyperVibe-Full-Setup-$VERSION-$ASSET_ARCH.zip"
NATIVE_PKG="$OUT/HyperVibe-Full-Setup-$VERSION-$ASSET_ARCH.pkg"
PKG_WORK="$BUILD_ROOT/staging/pkg/$VERSION"
PKG_ROOT="$PKG_WORK/root"
PKG_SCRIPTS="$PKG_WORK/scripts"
PKG_RESOURCES="$PKG_WORK/resources"
PKG_COMPONENT="$PKG_WORK/HyperVibePayload.pkg"
PKG_DISTRIBUTION="$PKG_WORK/Distribution.xml"
PKG_UNSIGNED="$PKG_WORK/HyperVibe-unsigned.pkg"

/bin/rm -rf "$OUT" "$PKG_WORK"
/bin/mkdir -p "$PAYLOAD/Legal"

echo "→ assembling $MODE payload ($VERSION, $ASSET_ARCH)"
/bin/cp -R "$APP_SOURCE" "$PAYLOAD/HyperVibe.app"
/bin/cp -R "$ROOT/mic/driver/SiriRemoteMic.driver" "$PAYLOAD/"
/bin/cp "$ROOT/mic/router/srm_router" "$PAYLOAD/"
/bin/cp "$ROOT/mic/captured/srm_captured" "$PAYLOAD/"
/bin/cp "$ROOT/mic/captured/au.holodata.SiriRemoteMic.captured.plist" "$PAYLOAD/"
/bin/cp "$DIST/do_install.sh" "$PAYLOAD/"
/bin/cp "$DIST/do_uninstall.sh" "$PAYLOAD/"
/bin/cp "$ROOT/LICENSE" "$PAYLOAD/Legal/GPL-3.0.txt"
/bin/cp "$ROOT/NOTICE" "$PAYLOAD/Legal/NOTICE.txt"
/bin/cp "$ROOT/mic/driver/vendor/BlackHole-LICENSE.txt" "$PAYLOAD/Legal/BlackHole-LICENSE.txt"
/bin/cp "$ROOT/mic/router/Opus-LICENSE.txt" "$PAYLOAD/Legal/Opus-LICENSE.txt"

if [ "$MODE" = "public" ]; then
    CONFIG_SOURCE="$ROOT/examples/config.jsonc"
else
    if [ -z "$CONFIG_SOURCE" ]; then
        CONFIG_SOURCE="$HOME/.config/siriremote/config.jsonc"
    fi
    [ -f "$CONFIG_SOURCE" ] || { echo "personal config not found: $CONFIG_SOURCE" >&2; exit 1; }
fi
/bin/cp "$CONFIG_SOURCE" "$PAYLOAD/config.jsonc"

if [ "$WITH_PACKETLOGGER" -eq 1 ]; then
    [ "$MODE" = "personal" ] || { echo "PacketLogger requires --personal" >&2; exit 2; }
    [ -d /Applications/PacketLogger.app ] || {
        echo "/Applications/PacketLogger.app not found" >&2
        exit 1
    }
    /bin/cp -R /Applications/PacketLogger.app "$PAYLOAD/PacketLogger.app"
fi

if [ "$MODE" = "public" ]; then
    [ ! -d "$PAYLOAD/PacketLogger.app" ] || {
        echo "REFUSED: PacketLogger found in public payload" >&2
        exit 2
    }
    /usr/bin/cmp -s "$PAYLOAD/config.jsonc" "$ROOT/examples/config.jsonc" || {
        echo "REFUSED: public payload config is not examples/config.jsonc" >&2
        exit 2
    }
fi

COMMIT="${HYPERVIBE_SOURCE_COMMIT:-$(git rev-parse HEAD)}"
/usr/bin/printf '%s\n' \
    "HyperVibe release: $VERSION" \
    "Source commit: $COMMIT" \
    "Architecture: $ARCHS" \
    "Package mode: $MODE" \
    "Personal config bundled: $([ "$MODE" = "personal" ] && echo yes || echo no)" \
    "PacketLogger bundled: $([ "$WITH_PACKETLOGGER" -eq 1 ] && echo yes || echo no)" \
    > "$PAYLOAD/BUILD-INFO.txt"

echo "→ building uninstaller"
/usr/bin/osacompile -l AppleScript -o "$UNINSTALL_APP" "$DIST/uninstaller.applescript"
/bin/cp "$DIST/do_uninstall.sh" "$UNINSTALL_APP/Contents/Resources/do_uninstall.sh"
/usr/libexec/PlistBuddy -c "Set :CFBundleName HyperVibe Uninstall" \
    "$UNINSTALL_APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string HyperVibe Uninstall" \
        "$UNINSTALL_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.hypervibe.uninstall" \
    "$UNINSTALL_APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.hypervibe.uninstall" \
        "$UNINSTALL_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" \
    "$UNINSTALL_APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" \
        "$UNINSTALL_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$UNINSTALL_APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" \
        "$UNINSTALL_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$UNINSTALL_APP"
/bin/cp -R "$UNINSTALL_APP" "$PAYLOAD/HyperVibe Uninstall.app"

echo "→ sealing payload manifest"
(
    cd "$PAYLOAD"
    while IFS= read -r -d '' item; do
        /usr/bin/shasum -a 256 "$item"
    done < <(/usr/bin/find . -type f ! -name PAYLOAD-SHA256SUMS.txt -print0 | LC_ALL=C /usr/bin/sort -z)
) > "$PAYLOAD/PAYLOAD-SHA256SUMS.txt"

echo "→ building setup app"
/usr/bin/osacompile -l AppleScript -o "$SETUP_APP" "$DIST/installer.applescript"
/bin/cp -R "$PAYLOAD" "$SETUP_APP/Contents/Resources/payload"
/usr/libexec/PlistBuddy -c "Set :CFBundleName HyperVibe Setup" \
    "$SETUP_APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string HyperVibe Setup" \
        "$SETUP_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.hypervibe.setup" \
    "$SETUP_APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.hypervibe.setup" \
        "$SETUP_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" \
    "$SETUP_APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" \
        "$SETUP_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$SETUP_APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" \
        "$SETUP_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$SETUP_APP"

echo "→ building native macOS Installer package"
/bin/mkdir -p "$PKG_ROOT/Library/Application Support/HyperVibe Installer" \
    "$PKG_SCRIPTS" "$PKG_RESOURCES"
/bin/cp -R "$PAYLOAD" "$PKG_ROOT/Library/Application Support/HyperVibe Installer/payload"
/bin/cp "$DIST/pkg/postinstall" "$PKG_SCRIPTS/postinstall"
/bin/chmod 755 "$PKG_SCRIPTS/postinstall"
/bin/cp "$DIST/pkg/resources/welcome.html" "$PKG_RESOURCES/welcome.html"
/bin/cp "$DIST/pkg/resources/readme.html" "$PKG_RESOURCES/readme.html"
/bin/cp "$DIST/pkg/resources/conclusion.html" "$PKG_RESOURCES/conclusion.html"
/bin/cp "$ROOT/LICENSE" "$PKG_RESOURCES/license.txt"
/usr/bin/sed "s/@@VERSION@@/$APP_VERSION/g" \
    "$DIST/pkg/Distribution.xml" > "$PKG_DISTRIBUTION"

/usr/bin/pkgbuild \
    --root "$PKG_ROOT" \
    --scripts "$PKG_SCRIPTS" \
    --component-plist "$DIST/pkg/components.plist" \
    --identifier com.hypervibe.full \
    --version "$APP_VERSION" \
    --install-location / \
    --ownership recommended \
    "$PKG_COMPONENT"
/usr/bin/productbuild \
    --distribution "$PKG_DISTRIBUTION" \
    --resources "$PKG_RESOURCES" \
    --package-path "$PKG_WORK" \
    "$PKG_UNSIGNED"

if [ -n "${HYPERVIBE_INSTALLER_SIGN_IDENTITY:-}" ]; then
    SIGN_ARGS=(--sign "$HYPERVIBE_INSTALLER_SIGN_IDENTITY")
    if [ -n "${HYPERVIBE_INSTALLER_KEYCHAIN:-}" ]; then
        SIGN_ARGS+=(--keychain "$HYPERVIBE_INSTALLER_KEYCHAIN")
    fi
    /usr/bin/productsign "${SIGN_ARGS[@]}" "$PKG_UNSIGNED" "$NATIVE_PKG"
    /bin/rm -f "$PKG_UNSIGNED"
else
    /bin/mv "$PKG_UNSIGNED" "$NATIVE_PKG"
    echo "⚠ native package is unsigned: set HYPERVIBE_INSTALLER_SIGN_IDENTITY to a Developer ID Installer identity for public trust"
fi

echo "→ creating Release archives"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_SOURCE" "$APP_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$SETUP_APP" "$FULL_ZIP"
(
    cd "$OUT"
    /usr/bin/shasum -a 256 "$(basename "$APP_ZIP")" "$(basename "$FULL_ZIP")" \
        "$(basename "$NATIVE_PKG")"
) > "$OUT/SHA256SUMS.txt"

echo
echo "✓ $APP_ZIP"
echo "✓ $FULL_ZIP"
echo "✓ $NATIVE_PKG"
echo "✓ $OUT/SHA256SUMS.txt"
if [ "$MODE" = "personal" ]; then
    echo "⚠ personal build: never upload these assets publicly"
fi
