#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
clang -Iapp -c app/tests/ring/Devices.c -o "$work/devices.o"
swiftc -module-cache-path "$PWD/app/.build/module-cache" -Xcc -I"$PWD/app" \
    -import-objc-header app/tests/ring/Devices.h app/tests/ring/main.swift \
    app/TouchHandler.swift app/TouchSnapshot.swift SiriRemoteCore/Sources/SiriRemoteCore/CircularScroll.swift \
    "$work/devices.o" -o "$work/ring-tests"
"$work/ring-tests"
