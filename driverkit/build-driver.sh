#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

xcodebuild \
    -project "$SCRIPT_DIR/SiriRemoteMicDriver.xcodeproj" \
    -scheme SiriRemoteMicDriver \
    -configuration Debug \
    -sdk driverkit25.5 \
    -derivedDataPath "$REPOSITORY_ROOT/.build/driverkit" \
    SYMROOT="$REPOSITORY_ROOT/.build/driverkit/Products" \
    OBJROOT="$REPOSITORY_ROOT/.build/driverkit/Intermediates.noindex" \
    SHARED_PRECOMPS_DIR="$REPOSITORY_ROOT/.build/driverkit/PrecompiledHeaders" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
