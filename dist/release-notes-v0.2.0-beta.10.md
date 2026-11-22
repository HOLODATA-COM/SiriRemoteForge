# HyperVibe 0.2.0-beta.10

This macOS update fixes three cases where the Siri Remote’s outer ring could appear to stop scrolling.

- **Holding the layer key to scroll.** Hold the layer key, turn the ring for horizontal scrolling, then release the key. Your previous layer is restored. A tap on the layer key still switches layers.
- **Reconnecting a remote.** When macOS reconnects a touch surface under the same device ID, HyperVibe attaches to the new service. A second connected remote can keep scrolling while the first recovers.
- **Starting the next gesture.** If a button press interrupts scrolling or a finger-up report goes missing, the next contact gets a fresh start. Horizontal scrolling also sends its end event when a gesture is interrupted.

## Updating from beta.9

On Apple silicon running macOS 13 or later, open HyperVibe’s menu and choose **Check for Updates…**. The App update contains all three fixes.

For a manual update, download `HyperVibe-0.2.0-beta.10-macOS-arm64.zip`. For a first installation including the microphone services, use `HyperVibe-Full-Setup-0.2.0-beta.10-arm64.pkg`. The legacy Full Setup ZIP is also available. Public App bundles are ad-hoc signed. The Installer is unsigned and the downloads are unnotarized.

## Verification

The release includes automated touch-frame and device-reconnection regressions alongside the existing core test suite. The tests replay missing lift events, overlapping reports from two remotes and reused device IDs without sending input to the desktop.
