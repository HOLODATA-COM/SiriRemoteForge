#!/bin/bash
# Build a pinned static libopus for the Release deployment target.
#
# Homebrew bottles inherit the build host's minimum macOS version. Linking such a bottle into a
# macOS 13 Release on a newer host produces a deceptively 13-tagged executable containing objects
# built for the newer OS. Build the official source ourselves instead.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
OPUS_VERSION="1.6.1"
OPUS_SHA256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz"
MACOS_MIN="${HYPERVIBE_MACOS_MIN:-13.0}"
ARCH="$(uname -m)"
CACHE="$ROOT/dist/build/cache"
TOOLCHAIN="$ROOT/dist/build/toolchain"
PREFIX="$TOOLCHAIN/opus-$OPUS_VERSION-$ARCH-macos$MACOS_MIN"
ARCHIVE="$CACHE/opus-$OPUS_VERSION.tar.gz"
WORK="$TOOLCHAIN/opus-$OPUS_VERSION-source"

case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "unsupported build architecture: $ARCH" >&2; exit 2 ;;
esac

if [ -f "$PREFIX/lib/libopus.a" ] && [ -f "$PREFIX/include/opus/opus.h" ]; then
    echo "→ using cached libopus $OPUS_VERSION ($ARCH, macOS $MACOS_MIN)" >&2
    echo "$PREFIX"
    exit 0
fi

for tool in /usr/bin/curl /usr/bin/make /usr/bin/shasum /usr/bin/tar; do
    [ -x "$tool" ] || { echo "missing build tool: $tool" >&2; exit 1; }
done
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
CLANG_PATH="$(xcrun --find clang)"

/bin/mkdir -p "$CACHE" "$TOOLCHAIN"
if [ ! -f "$ARCHIVE" ]; then
    echo "→ downloading official libopus $OPUS_VERSION source" >&2
    /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 \
        "$OPUS_URL" --output "$ARCHIVE.partial"
    /bin/mv "$ARCHIVE.partial" "$ARCHIVE"
fi

ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{ print $1 }')"
[ "$ACTUAL_SHA256" = "$OPUS_SHA256" ] || {
    echo "REFUSED: libopus source checksum mismatch: $ARCHIVE" >&2
    exit 1
}

echo "→ building static libopus for macOS $MACOS_MIN" >&2
/bin/rm -rf "$WORK" "$PREFIX"
/bin/mkdir -p "$WORK"
/usr/bin/tar -xzf "$ARCHIVE" -C "$WORK" --strip-components 1

(
    cd "$WORK"
    /usr/bin/env \
        CC="$CLANG_PATH" \
        MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
        CFLAGS="-O2 -arch $ARCH -isysroot $SDK_PATH -mmacosx-version-min=$MACOS_MIN" \
        LDFLAGS="-arch $ARCH -mmacosx-version-min=$MACOS_MIN" \
        ./configure \
            --prefix="$PREFIX" \
            --disable-shared \
            --enable-static \
            --disable-extra-programs \
            --disable-doc >&2
    /usr/bin/make -j"$(/usr/sbin/sysctl -n hw.ncpu)" >&2
    /usr/bin/make install >&2
)

[ -f "$PREFIX/lib/libopus.a" ] || { echo "libopus build did not produce libopus.a" >&2; exit 1; }
[ -f "$PREFIX/include/opus/opus.h" ] || { echo "libopus build did not install headers" >&2; exit 1; }
echo "$PREFIX"
