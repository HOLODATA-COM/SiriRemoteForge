#!/bin/bash
# Build the "Siri Remote Mic" CoreAudio HAL plug-in (an AudioServerPlugIn bundle).
# No Xcode project needed — a HAL plug-in is just a bundle with a compiled dylib.
# Source is the Siri Remote Mic fork; our config is injected with -include.
set -e
cd "$(dirname "$0")"

SDK="$(xcrun --show-sdk-path --sdk macosx)"
DRIVER="SiriRemoteMic.driver"
EXE="SiriRemoteMic"
CAPTURE_APP="SiriRemoteMicCaptureTest.app"
# Optional stable signing identity for the capture-test app (keeps its microphone TCC grant across
# rebuilds). Set SRM_CAPTURE_SIGN_IDENTITY to your own "Apple Development: …" identity; unset → ad-hoc.
CAPTURE_SIGN_IDENTITY="${SRM_CAPTURE_SIGN_IDENTITY:-}"

rm -rf "$DRIVER"
rm -rf "$CAPTURE_APP"
mkdir -p "$DRIVER/Contents/MacOS"
mkdir -p "$CAPTURE_APP/Contents/MacOS"
cp Info.plist "$DRIVER/Contents/Info.plist"
cp CaptureTest-Info.plist "$CAPTURE_APP/Contents/Info.plist"

clang -bundle -O2 \
    -Wall -Wextra -Werror \
    -isysroot "$SDK" \
    -include SiriRemoteMic.config.h \
    SiriRemoteMic.c \
    -framework CoreFoundation -framework CoreAudio -framework Accelerate \
    -o "$DRIVER/Contents/MacOS/$EXE"

clang -O2 -Wall -Wextra -Werror srm_test_writer.c -o srm_test_writer
clang -O2 -Wall -Wextra -Werror srm_capture_test.c \
    -framework CoreFoundation -framework CoreAudio \
    -o "$CAPTURE_APP/Contents/MacOS/SiriRemoteMicCaptureTest"
clang -O2 -Wall -Wextra -Werror srm_usage_monitor.c \
    -framework CoreFoundation -framework CoreAudio \
    -o srm_usage_monitor
clang -O2 -Wall -Wextra -Werror srm_notify_listener.c -o srm_notify_listener
clang -O2 -Wall -Wextra -Werror srm_driver_contract_test.c \
    -framework CoreFoundation -framework CoreAudio \
    -o srm_driver_contract_test
clang -O2 -Wall -Wextra -Werror -isysroot "$SDK" srm_io_sim.c \
    -framework CoreFoundation -framework CoreAudio \
    -o srm_io_sim

# HAL plug-ins must be signed; ad-hoc is fine for a local install (BlackHole ships signed,
# but self-built + ad-hoc loads on this machine — no paid account, no DriverKit wall).
codesign --force --sign - "$DRIVER"
if [ -n "$CAPTURE_SIGN_IDENTITY" ] && security find-identity -v -p codesigning | grep -Fq "\"$CAPTURE_SIGN_IDENTITY\""; then
    codesign --force --sign "$CAPTURE_SIGN_IDENTITY" "$CAPTURE_APP"
    echo "✓ capture test signed with stable development identity"
else
    codesign --force --sign - "$CAPTURE_APP"
    echo "! capture test ad-hoc signed (set SRM_CAPTURE_SIGN_IDENTITY for stable TCC identity)"
fi

echo "✓ built $DRIVER"
codesign -dv "$DRIVER" 2>&1 | grep -E 'Identifier|Signature' || true
"./srm_driver_contract_test" "$DRIVER/Contents/MacOS/$EXE"
# coreaudiod-style IO simulation (~9 s, 3 phases): proves ReadInput continuity, idempotency
# under a second client, resync recovery, no full-scale garbage, the device clock rate, AND the
# built-in-mic fallback (remote fresh -> remote; remote stale -> built-in ring within
# kSRM_RemoteStaleFrames; remote resume -> back; crossfaded switches; clean silence when the
# built-in ring is absent) — offline.
"./srm_io_sim" "$DRIVER/Contents/MacOS/$EXE"
echo "system install remains fail-closed in ./install.sh; do not bypass without explicit approval"
