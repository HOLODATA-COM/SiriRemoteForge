#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

OPUS_PREFIX="$(brew --prefix opus 2>/dev/null || echo /opt/homebrew)"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
MODULE_CACHE="/private/tmp/srm-router-module-cache"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

clang -c -O2 -Wall -Wextra -Werror \
    -isysroot "$SDK_PATH" \
    SiriRemoteMicRingWriter.c \
    -o SiriRemoteMicRingWriter.o

clang -c -O2 -Wall -Wextra -Werror \
    -isysroot "$SDK_PATH" \
    MonitorAudioRing.c \
    -o MonitorAudioRing.o

swiftc \
    -sdk "$SDK_PATH" \
    -import-objc-header router_shim.h \
    -I"$OPUS_PREFIX/include" \
    -L"$OPUS_PREFIX/lib" -lopus \
    -framework AVFoundation \
    ../OpusVoiceDecoder.swift VoiceFrameParser.swift PklgTailReader.swift \
    MonitorPlayer.swift SiriRemoteMicRouter.swift \
    SiriRemoteMicRingWriter.o MonitorAudioRing.o \
    -o srm_router

swiftc \
    -sdk "$SDK_PATH" \
    VoiceFrameParser.swift test_parser.swift \
    -o test_parser

# Jitter-buffer render logic: the one live-audio-only path we can validate offline.
clang -O2 -Wall -Wextra -Werror \
    -isysroot "$SDK_PATH" \
    test_monitor_ring.c MonitorAudioRing.c \
    -o test_monitor_ring

./test_parser
./test_monitor_ring
echo "router build: PASS"
