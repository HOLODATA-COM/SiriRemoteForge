#!/bin/bash

# Build script for HyperVibe
# Make sure Xcode Command Line Tools are installed: xcode-select --install

set -e

echo "Building HyperVibe..."

SWIFT_FILES=(
    "main.swift"
    "SiriRemoteApp.swift"
    "MenuBarManager.swift"
    "RemoteDetector.swift"
    "RemoteInputHandler.swift"
    "GATTDiagnostics.swift"
    "NativePushToTalk.swift"
    "CursorController.swift"
    "MediaController.swift"
    "MediaKeyInterceptor.swift"
    "TouchHandler.swift"
    "CursorHighlighter.swift"
    "LayerHUD.swift"
    # --- Settings UI (SwiftUI) ---
    "TuneSettings.swift"
    "SettingsModel.swift"
    "LaunchAtLogin.swift"
    "DeviceInfo.swift"
    "SettingsView.swift"
    "SettingsWindow.swift"
    "RemoteView.swift"
    "LayoutView.swift"
    # --- Config engine integration (this fork) ---
    "KeyMap.swift"
    "MacActionExecutor.swift"
    "Spaces.swift"
    "Brightness.swift"
    "AppWatcher.swift"
    "ConfigStore.swift"
    "ConfigFileWatcher.swift"
    # --- SiriRemoteCore (pure engine, compiled into the binary) ---
    "../SiriRemoteCore/Sources/SiriRemoteCore/JSONC.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/Action.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/Config.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/ConfigLoader.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/ConfigWriter.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/Events.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/CircularScroll.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/MappingEngine.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/Controller.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/Placeholder.swift"
)

# Find SDK path
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || echo "")

if [ -z "$SDK_PATH" ]; then
    echo "Error: macOS SDK not found. Please install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

echo "Using SDK: $SDK_PATH"

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" == "arm64" ]; then
    TARGET="arm64-apple-macosx13.0"
else
    TARGET="x86_64-apple-macosx13.0"
fi

echo "Building for: $TARGET"

# Build
swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -o HyperVibe \
    "${SWIFT_FILES[@]}" \
    -import-objc-header SiriRemote-Bridging-Header.h \
    -F /System/Library/PrivateFrameworks \
    -framework IOKit \
    -framework CoreGraphics \
    -framework AudioToolbox \
    -framework Carbon \
    -framework AppKit \
    -framework CoreBluetooth \
    -framework SwiftUI \
    -framework MultitouchSupport

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Build successful!"
    echo ""
    echo "To create a proper macOS app bundle, run:"
    echo "  ./create_app_bundle.sh"
    echo ""
    echo "Or run directly with:"
    echo "  ./HyperVibe"
else
    echo ""
    echo "✗ Build failed!"
    exit 1
fi
