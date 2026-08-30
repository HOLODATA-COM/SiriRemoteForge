# HyperVibe public-API probes

These two minimal command-line tools reproduce the public-framework side of the Feedback Assistant
reports. They contain no HyperVibe input code, private frameworks, packet capture, Bluetooth
addresses, credentials, or device-specific constants.

Requirements: macOS 13 or later, Xcode command-line tools, and a third-generation USB-C Siri Remote
already paired in Bluetooth settings.

Run the following commands from this `PublicAPIProbe` directory.

## InputProbe

`InputProbe` asks Game Controller for every currently connected controller, prints the public
profile and element aliases, and timestamps every value-change callback it receives.

```sh
swift run InputProbe --seconds 30
```

If the paired Remote is not returned, repeat once with explicit Game Controller discovery:

```sh
swift run InputProbe --discover --seconds 30
```

During the 30-second window, press every button, rotate and tap the click ring, then move one finger
over the complete touch surface. Copy the console output into the input Feedback report. The probe
does not suppress system gestures or claim exclusive input routing.

## AudioInputProbe

`AudioInputProbe` enumerates public CoreAudio devices that expose input streams and prints their
name, UID, manufacturer, transport code, and nominal sample rate.

```sh
swift run AudioInputProbe
```

Run this on a clean test system before installing HyperVibe's virtual microphone. If the virtual
device is already installed, its name and `SRMDevice_UID` identify it as project-created evidence,
not a native Siri Remote audio endpoint.

## Attachment hygiene

Review the console output before attaching it. Remove the Mac user name from shell prompts and omit
Bluetooth addresses, serial numbers, unrelated audio-device UIDs, or other personal identifiers.
Attach this complete source directory alongside the scrubbed output so Apple can build the exact
public-framework probe.
