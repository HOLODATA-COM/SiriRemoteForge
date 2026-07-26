#!/bin/bash
# Build the "Siri Remote Mic" capture daemon (srm_captured). Pure libSystem — libnotify and
# libdispatch need no extra link flags.
set -e
cd "$(dirname "$0")"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
MACOS_MIN="${HYPERVIBE_MACOS_MIN:-13.0}"
clang -O2 -Wall -Wextra -Werror \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MACOS_MIN" \
    srm_captured.c -o srm_captured
echo "✓ built srm_captured"
