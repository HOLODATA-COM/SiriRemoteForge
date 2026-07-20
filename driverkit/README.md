# Siri Remote microphone DriverKit proof of concept

This directory contains a local HIDDriverKit replacement experiment and its separate macOS host.
They stay isolated from HyperVibe because the normal app uses a different signing/runtime model and
must keep its existing Accessibility and Input Monitoring grants.

## Current result

Both targets build successfully with Xcode 26.6 and the DriverKit 25.5 SDK:

- `SiriRemoteMicDriver` is an arm64 `IOUserHIDEventService` DEXT;
- `SiriRemoteMicHost` embeds that DEXT and submits only an explicit Activate or Deactivate request;
- both bundles can be signed inside-out with the local Apple Development identity, hardened runtime
  enabled, and pass strict nested `codesign` verification.

The first signed launch on 2026-07-20 was stopped by AMFI before the host reached `main`:

```text
AppleMobileFileIntegrityError Code=-413 "No matching profile found"
taskgated-helper: no eligible provisioning profiles found
```

Consequently no `OSSystemExtensionRequest` was submitted, no system extension was registered, and
`systemextensionsctl list` remained unchanged. This is a precise provisioning failure, not a
microphone result and not something administrator/root permission bypasses.

## Driver behavior

The personality matches only the tested remote's audio HID surface:

- Apple vendor ID `76`, product ID `789`;
- primary usage page `0x0C`, usage `0x04`, corresponding to the IORegistry node previously
  enumerated as Bluetooth HID interface 5. The BLE `IOHIDInterface` provider does not expose a
  matchable `bInterfaceNumber`, so the personality does not rely on it.

It uses the default match category and an experimental probe score of `8000`, above the observed
`AppleEmbeddedBluetoothAudio` score of `7175`. Registration therefore makes it a candidate
replacement, not a passive observer. Existing providers may still require recreation/rematching,
and ownership must always be confirmed in IORegistry.

After `Start` succeeds, the DEXT sends the evidence-backed Feature report `0xFF [0xAF]` through its
`IOHIDInterface` provider and logs the exact `IOReturn`. It then logs incoming reports, bounded to
209 bytes per report. A zero-frame run is meaningful only together with the activation return code
and verified interface ownership.

## Build and sign without activation

```sh
cd /Users/zhangwenqian/siriremote-release/driverkit
./build-host.sh

# Paste the exact identity string shown by `security find-identity -v -p codesigning`.
./sign-host-development.sh 'Apple Development: Name (certificate suffix)'

# Once both eligible profiles exist, embed them before the same inside-out signing pass.
./sign-host-development.sh 'Apple Development: Name (certificate suffix)' \
  /path/to/SiriRemoteMicHost.provisionprofile \
  /path/to/SiriRemoteMicDriver.provisionprofile
```

`build-host.sh` first builds the DEXT, then compiles the host and embeds the extension at
`Contents/Library/SystemExtensions/com.hypervibe.SiriRemoteMicDriver.dext`. It writes only beneath
the repository's ignored `.build/` directory. Neither script launches the host, installs a system
extension, changes SIP, restarts Bluetooth, changes pairing, or stops HyperVibe.

With one argument, the signing script performs structural development signing without a profile.
With three arguments, it validates and embeds the supplied host and DEXT profiles before signing
inside-out. Re-run `build-host.sh` first when switching between those modes so stale profiles cannot
survive in the ignored build product.

The host is inert when launched without an argument. Its UI has explicit Activate and Deactivate
buttons; the executable also accepts exactly one of `--activate` and `--deactivate` for a controlled
trial.

## Provisioning gate

The current certificate is valid for development signing, but the machine has no eligible profiles
for these restricted entitlements:

- DEXT: `com.apple.developer.driverkit`,
  `com.apple.developer.driverkit.transport.hid`, and
  `com.apple.developer.driverkit.family.hid.eventservice`;
- host: `com.apple.developer.system-extension.install`.

A certificate authorizes an identity; a provisioning profile separately authorizes that identity,
bundle ID, and entitlement set. The signed host is therefore killed by AMFI before its application
code runs. The certificate's displayed parenthetical suffix is also not the Team Identifier: the
actual signed TeamIdentifier here is `5S6YD5B7F4`.

On 2026-07-20, an explicit `xcodebuild -allowProvisioningUpdates` request reached Apple's service
for that Team Identifier. Xcode rejected it before producing a profile: the logged-in **Personal
development team** (`James Zhang`) does not support DriverKit Transport HID, DriverKit Family HID
EventService, or DriverKit development capabilities. This rules out automatic provisioning from the
current free/personal team; it does not indicate a source, certificate, or local-admin failure.

Once eligible profiles exist, the signed host must be copied as a complete bundle to `/Applications`
or another system-recognized Applications directory before activation. Running the activation host
from `.build/` would otherwise encounter the separate
[`unsupportedParentBundleLocation`](https://developer.apple.com/documentation/systemextensions/ossystemextensionerror/unsupportedparentbundlelocation)
gate.

Changing recovery/SIP security state is a separate workflow and is not performed by any script in
this repository.

## Bounded activation acceptance test

After both profiles are available, the first test should remain narrow and reversible:

1. rebuild, embed both eligible profiles while signing, verify both hardened-runtime signatures,
   and copy the complete host to `/Applications`;
2. temporarily stop the one normal HyperVibe process and verify that its interface-5 HID client is
   gone;
3. submit activation from the installed host and, if requested, approve it in **System Settings →
   General → Login Items & Extensions → Drivers**;
4. verify both `systemextensionsctl` state and IORegistry ownership. Activation only registers the
   DEXT; do not infer that it displaced `AppleEmbeddedBluetoothAudio` without this check;
5. confirm the DEXT's automatic Feature `0xFF [0xAF]` write returned success, then hold Siri for one
   bounded capture;
6. treat an interface-5 callback with local `reportID=0xFF`, an expected-length varying payload,
   and plausible Opus bytes (commonly TOC `0xB8`) as the capture criterion. Wire/GATT report `0xFA`
   is protocol evidence; macOS rewrites this interface's local ID to `0xFF`, so a literal `0xFA`
   must not be required;
7. request deactivation, allowing for a deferred/reboot result, verify restoration of
   `AppleEmbeddedBluetoothAudio`, and restore exactly one no-argument HyperVibe instance.

Do not add Opus decoding or a virtual CoreAudio device until a genuine varying microphone payload
has been captured.
