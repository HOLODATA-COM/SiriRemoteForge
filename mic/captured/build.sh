#!/bin/bash
# Build the "Siri Remote Mic" capture daemon (srm_captured). Pure libSystem — libnotify and
# libdispatch need no extra link flags.
set -e
cd "$(dirname "$0")"
clang -O2 -Wall -Wextra -Werror srm_captured.c -o srm_captured
echo "✓ built srm_captured"
