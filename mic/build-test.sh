#!/bin/bash
# Compile + run the OpusVoiceDecoder offline self-test.
# Requires Homebrew opus: `brew install opus`.
set -e
cd "$(dirname "$0")"

OPUS_PREFIX="$(brew --prefix opus 2>/dev/null || echo /opt/homebrew)"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
MODULE_CACHE="/private/tmp/srm-opus-module-cache"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

swiftc \
    -sdk "$SDK_PATH" \
    -import-objc-header opus_shim.h \
    -I"$OPUS_PREFIX/include" \
    -L"$OPUS_PREFIX/lib" -lopus \
    OpusVoiceDecoder.swift test_decoder.swift \
    -o /tmp/opus_decoder_test

/tmp/opus_decoder_test
