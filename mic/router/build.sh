#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

OPUS_PREFIX="${HYPERVIBE_OPUS_PREFIX:-$(brew --prefix opus 2>/dev/null || echo /opt/homebrew)}"
OPUS_STATIC="$OPUS_PREFIX/lib/libopus.a"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
MACOS_MIN="${HYPERVIBE_MACOS_MIN:-13.0}"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macosx$MACOS_MIN"
MODULE_CACHE="/private/tmp/srm-router-module-cache"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

[ -f "$OPUS_STATIC" ] || {
    echo "static libopus not found: $OPUS_STATIC" >&2
    echo "install it first: brew install opus" >&2
    exit 1
}

clang -c -O2 -Wall -Wextra -Werror \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MACOS_MIN" \
    SiriRemoteMicRingWriter.c \
    -o SiriRemoteMicRingWriter.o

clang -c -O2 -Wall -Wextra -Werror \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MACOS_MIN" \
    MonitorAudioRing.c \
    -o MonitorAudioRing.o

swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -import-objc-header router_shim.h \
    -I"$OPUS_PREFIX/include" \
    "$OPUS_STATIC" \
    -framework AVFoundation \
    ../OpusVoiceDecoder.swift VoiceFrameParser.swift PklgTailReader.swift \
    MonitorPlayer.swift SiriRemoteMicRouter.swift \
    SiriRemoteMicRingWriter.o MonitorAudioRing.o \
    -o srm_router

swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    VoiceFrameParser.swift test_parser.swift \
    -o test_parser

# Jitter-buffer render logic: the one live-audio-only path we can validate offline.
clang -O2 -Wall -Wextra -Werror \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MACOS_MIN" \
    test_monitor_ring.c MonitorAudioRing.c \
    -o test_monitor_ring

./test_parser
./test_monitor_ring
echo "router build: PASS"
