#!/bin/bash
# Fetch and cache the exact Sparkle binary distribution used by the manual swiftc build.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPARKLE_VERSION="2.9.4"
SPARKLE_SHA256="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
CACHE_ROOT="${HYPERVIBE_SPARKLE_ROOT:-$SCRIPT_DIR/.build/vendor/Sparkle-${SPARKLE_VERSION}}"

if [ -d "$CACHE_ROOT/Sparkle.framework" ] \
    && [ -x "$CACHE_ROOT/bin/sign_update" ] \
    && [ -f "$CACHE_ROOT/LICENSE" ]; then
    echo "$CACHE_ROOT"
    exit 0
fi

if [ -e "$CACHE_ROOT" ]; then
    echo "Error: incomplete Sparkle cache at $CACHE_ROOT" >&2
    echo "Remove only that cache directory and rebuild." >&2
    exit 1
fi

TEMP_ROOT="$(/usr/bin/mktemp -d /private/tmp/hypervibe-sparkle.XXXXXX)"
cleanup() {
    /bin/rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

ARCHIVE="${HYPERVIBE_SPARKLE_ARCHIVE:-$TEMP_ROOT/Sparkle-${SPARKLE_VERSION}.tar.xz}"
if [ -z "${HYPERVIBE_SPARKLE_ARCHIVE:-}" ]; then
    echo "→ downloading Sparkle $SPARKLE_VERSION" >&2
    /usr/bin/curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        "$SPARKLE_URL" --output "$ARCHIVE"
fi
[ -f "$ARCHIVE" ] || { echo "Error: Sparkle archive not found: $ARCHIVE" >&2; exit 1; }

ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$SPARKLE_SHA256" ]; then
    echo "Error: Sparkle archive checksum mismatch" >&2
    echo "expected: $SPARKLE_SHA256" >&2
    echo "actual:   $ACTUAL_SHA256" >&2
    exit 1
fi

/usr/bin/tar -xf "$ARCHIVE" -C "$TEMP_ROOT"
for required in Sparkle.framework LICENSE bin/sign_update bin/generate_keys; do
    [ -e "$TEMP_ROOT/$required" ] || {
        echo "Error: Sparkle distribution is missing $required" >&2
        exit 1
    }
done

STAGE="$TEMP_ROOT/cache"
/bin/mkdir -p "$STAGE/bin" "$(dirname "$CACHE_ROOT")"
# ditto preserves the versioned framework's symlink topology. Flattening these links makes the
# bundle pass compilation but fail at runtime, so ordinary recursive file copies are not used.
/usr/bin/ditto "$TEMP_ROOT/Sparkle.framework" "$STAGE/Sparkle.framework"
/bin/cp "$TEMP_ROOT/LICENSE" "$STAGE/LICENSE"
/bin/cp "$TEMP_ROOT/bin/sign_update" "$TEMP_ROOT/bin/generate_keys" "$STAGE/bin/"
/bin/chmod 755 "$STAGE/bin/sign_update" "$STAGE/bin/generate_keys"
/bin/mv "$STAGE" "$CACHE_ROOT"

echo "$CACHE_ROOT"
