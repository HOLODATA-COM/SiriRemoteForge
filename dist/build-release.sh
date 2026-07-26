#!/bin/bash
# Cleanly rebuild every shipping component, then create public-safe Release assets.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
RELEASE_VERSION="${1:-}"

if [ -z "$RELEASE_VERSION" ]; then
    echo "usage: dist/build-release.sh VERSION  (example: 0.1.0-beta.1)" >&2
    exit 2
fi
if ! [[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "invalid release version: $RELEASE_VERSION" >&2
    exit 2
fi

if [ "${HYPERVIBE_ALLOW_DIRTY:-0}" != "1" ] && [ -n "$(git status --porcelain)" ]; then
    echo "REFUSED: release builds require a clean worktree" >&2
    echo "set HYPERVIBE_ALLOW_DIRTY=1 only for a local packaging test" >&2
    exit 2
fi

if [ "$(uname -m)" != "arm64" ]; then
    echo "REFUSED: the first public binary release is defined as Apple-silicon only" >&2
    exit 2
fi

APP_VERSION="${RELEASE_VERSION%%-*}"
BUILD_NUMBER="${HYPERVIBE_BUILD_NUMBER:-1}"
COMMIT="$(git rev-parse HEAD)"
OPUS_PREFIX="$(dist/build-opus.sh)"
APP_STAGE="$ROOT/dist/build/staging/$RELEASE_VERSION/HyperVibe.app"

case "$APP_STAGE" in
    "$ROOT/app/"*)
        echo "REFUSED: Release staging must never write inside app/" >&2
        exit 2
        ;;
esac

/bin/rm -rf "$ROOT/dist/build/staging/$RELEASE_VERSION"
/bin/mkdir -p "$(dirname "$APP_STAGE")"

echo "→ building HyperVibe $APP_VERSION ($COMMIT)"
(
    cd app
    ./build.sh
    HYPERVIBE_VERSION="$APP_VERSION" \
    HYPERVIBE_BUILD_NUMBER="$BUILD_NUMBER" \
    HYPERVIBE_SIGN_MODE=adhoc \
    HYPERVIBE_APP_BUNDLE_PATH="$APP_STAGE" \
        ./create_app_bundle.sh
)

echo "→ building microphone router"
(cd mic/router && HYPERVIBE_OPUS_PREFIX="$OPUS_PREFIX" ./build.sh)

echo "→ building microphone HAL plug-in"
(
    cd mic/driver
    HYPERVIBE_VERSION="$APP_VERSION" \
    HYPERVIBE_BUILD_NUMBER="$BUILD_NUMBER" \
        ./build.sh
)

echo "→ building capture daemon"
(cd mic/captured && ./build.sh)

echo "→ packaging public Release assets"
HYPERVIBE_SOURCE_COMMIT="$COMMIT" \
HYPERVIBE_APP_PATH="$APP_STAGE" \
    dist/package.sh --version "$RELEASE_VERSION"

dist/audit-release.sh "$RELEASE_VERSION"
