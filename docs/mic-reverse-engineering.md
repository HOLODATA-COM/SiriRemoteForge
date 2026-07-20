# Reverse-engineering the 3rd-gen Siri Remote microphone (living doc)

**Goal:** read the remote's built-in microphone on macOS and expose it as an audio input, so it can
be used as a far-field voice mic (voice-to-text at a distance) instead of the Mac's mic. The user
explicitly wants this integrated into siriRemote — reverse-engineering is the accepted path.

## Hardware / connection facts
- 3rd-gen Siri Remote (2022, USB-C, A2843-ish). HID **product `0x0315` (789)**, vendor `0x004C`
  (Apple), serial-as-name `C08RQGMC2330`. Connects over **BLE only** (`Services: 0x400000 <BLE>`);
  it advertises **no Bluetooth audio profile** (no A2DP/HFP), so the mic is NOT a normal audio device.
- It does **not** appear in CoreAudio (`system_profiler SPAudioDataType` — only MacBook mic, iPhone
  Continuity mic, etc.).
- macOS exposes seven virtual IOHID interfaces for this remote. The identified audio interface is
  **interface 5, usage `0x0C/0x04`, `MaxInputReportSize = 209`**, with
  `AppleEmbeddedBluetoothAudio` attached. Interface 2 carries the 3-byte `0xFB` button report;
  interface 0 (`0xFF00/0x0B`) hosts Apple device-management commands. Two more interfaces use page
  `0x20`. Normal app mode seizes the remote interfaces; `--direct-ptt` narrows seizure to audio only.

## Key finding (experiment done)
Added a **`--capture-mic`** diagnostic to the app: in `app/RemoteInputHandler.swift`,
`registerReportCapture()` calls `IOHIDDeviceRegisterInputReportCallback` and the top-level
`inputReportCallback` logs every raw input report > 6 bytes as `🎤 report id=.. len=.. <hex>` to
`/tmp/hypervibe.log`. Off by default; enable with `open HyperVibe.app --args --capture-mic`.

**Result:** holding the Siri button for ~3 s (button events `usage=0x4 → siri` value 1→0 are logged)
produced **ZERO large reports** (`grep -c "🎤 report"` = 0). So pressing Siri alone does NOT make the
remote stream voice. **Conclusion: the mic is HOST-ACTIVATED** — the remote streams voice only after
the paired host (Apple TV) sends a "start voice" command. A Mac never sends it, so the channel stays
dormant.

## Investigation roadmap

1. **Protocol research — complete.** The current gen-3 implementation identifies wire report
   `0xFA` as 99-byte Opus and enables writable Feature Report characteristics with byte `0xAF`.
2. **Enumerate the control surface — complete at IOHID, blocked at public CoreBluetooth.** All seven
   virtual interfaces are mapped. macOS does not expose its already-connected, system-owned HOGP
   peripheral to the app's CoreBluetooth session.
3. **Test public activation paths — exhausted on this Mac.** Full-interface `0xAF`, the Apple
   driver's `PushToTalk` property, and direct hidden Feature report `0x99` have all been tested with
   raw callbacks and exact IOReturn logging; none produced an audio-interface notification.
4. **Acquire real microphone frames — pending the local DriverKit replacement path.** The active
   scope stays on this Mac and the existing pairing; do not implement a decoder against guessed
   data.
5. **Decode and expose as CoreAudio input — pending frames.** Once frames exist, decode the verified
   Opus format and feed bounded PCM into a virtual input device.

## Risks / unknowns
- The activation may be **pairing-bound / encrypted** (keys negotiated during Apple-TV pairing) →
  could be a hard wall. The remote is currently paired to this Mac as a plain BLE-HID device, not via
  the Apple-TV Siri handshake, so the voice service may be gated.
- The 209-byte report might be a feature report that never fires as input without activation.
- **Hardware-in-the-loop:** sound near the remote is only a test signal after streaming starts. It
  cannot open the firmware gate. Upstream observes `0xFA` only while Siri is held; a truly unattended
  test therefore also needs a working programmatic PTT path, which this Mac currently rejects.

## Where things are
- App (canonical repo): `/Users/zhangwenqian/siriremote-release/app/` — build `./build.sh`, package
  `./create_app_bundle.sh`, run `HyperVibe.app` (signed with the stable "siriRemote Local Signing"
  cert; permissions persist). Capture: `open HyperVibe.app --args --capture-mic`, then read
  `/tmp/hypervibe.log`. HID open/seize is in `app/RemoteInputHandler.swift:setRemoteDevice`; the
  device is matched/enumerated in `app/RemoteDetector.swift`.
- Repo: github.com/HOLODATA-COM/SiriRemoteForge (`main`).

## Status log
- 2026-07-20: confirmed mic is host-activated (Siri press → no voice reports). Handed the reverse-
  engineering to a Fable agent (research + enumerate feature reports / GATT + attempt activation).
- 2026-07-20: Fable added two opt-in diagnostics to `RemoteInputHandler.swift`:
  `--dump-reports` enumerates HID elements/report sizes and reads feature reports;
  `--activate-mic` registers raw capture and probes candidate output/feature report IDs with the
  `0xAF` byte used by the Yanndroid/SiriRemote-Linux implementation.
- 2026-07-20: the first activation run did **not** produce voice frames. The runtime log recorded:
  - output IDs 0...5: `SetReport` returned `0xE00002F0`;
  - one-byte feature writes on several non-digitizer interfaces returned success, including ID 255,
    but this does not prove that the intended BLE GATT characteristic was reached;
  - on primary usage page `0x0D`, feature writes returned `0xE00002BC`, including ID 255;
  - the padded 208-byte feature-ID-255 write returned `0xE00002BC`;
  - readable digitizer features remained ID 0 = `00 01`, ID 1 = `01 db 00 49 00`;
  - no `🎤 report` lines appeared.
- 2026-07-20 15:30–15:32 AEST: with explicit user approval, attempted the narrow system-driver
  experiment `kmutil unload --class-name AppleEmbeddedBluetoothAudio` first as the user and then
  through macOS administrator authorization. Both requests reached `kernelmanagerd`; the service
  remained active with the same registry ID. The installed Apple kext does not opt into user
  termination, so the RELEASE kernel protects it even from an administrator request.
- 2026-07-20 15:45–15:46 AEST: added and ran bounded `--direct-ptt`. All seven callbacks attached,
  six `[0xAF]` re-arm writes succeeded, but direct Feature `0x99 [01]` and its automatic `[00]`
  release both returned `0xE00002BC`. No audio report arrived and interface 5 stayed at zero
  report-available calls/runs.
- 2026-07-20 evening AEST: with user approval, SIP was disabled and `amfi_get_out_of_my_way=1` set,
  which let the host run and the DEXT reach `[activated enabled]`. IOKit **did** select the DEXT for
  the audio provider (probe score 8000 beats 7175), but it could never launch: AMFI-off breaks
  DriverKit's exec path (`ENOEXEC`), AMFI-on kills it for `Taskgated Invalid Signature`. The DEXT
  was uninstalled and the boot-arg removed; **SIP is still disabled and should be re-enabled.**
- 2026-07-20 19:24 AEST: the decisive experiment — HyperVibe itself **seized interface 5**, removing
  Apple's driver from the path. `0xAF` Feature writes succeeded on six interfaces; the user held Siri
  ~9 s while speaking; **zero frames on interface 5**. `bluetoothd` showed the remote refusing every
  write with `CBATTErrorDomain Code=130`, and revealed that macOS maps the local `0xFF` write down to
  GATT report **ID 241**.
- 2026-07-20 19:33 AEST: USB-C experiment. The remote enumerates as `Apple TV Remote` exposing only
  `Device Management` (`0xFF00/0x0B`, maxFeature 25) and `Consumer Control`; **no audio interface over
  USB**. `SET feature 0xFF [AF]` was **accepted** over USB, but a subsequent ~8 s Siri hold still
  produced zero BLE audio frames.
- 2026-07-20 (late): **conclusion corrected.** Upstream activation is defined over raw GATT handles
  (`0xAF` → handle `0x001d`; CCCD `0x01 0x00` → handle `0x0024`; data from `0x0023`). macOS exposes
  neither handles nor CCCD control, so no attempt recorded above is known to have addressed the right
  characteristic. The microphone is **not** proven firmware-locked; the real boundary is macOS
  denying raw GATT for a device its HOGP stack owns.
- 2026-07-20 19:52 AEST: **decisive and final.** The remote was unpaired and the USB cable removed, a
  CoreBluetooth tool connected to it directly as an ordinary BLE peripheral, and **macOS still
  refused to expose HID service `0x1812`** — `discoverServices(nil)` and an explicit
  `discoverServices([0x1812])` both returned only `180A` and `180F`, even though the remote
  advertises HID. CoreBluetooth does not expose HID-over-GATT to third-party apps under any
  circumstances. With IOHID rewriting report IDs and owning CCCD state, **no public macOS API can
  reach the activation characteristic.** The investigation is closed on this platform.
- Diagnostic note: the interactive shell aliases `log`, which silently returned nothing for several
  sessions. Always invoke `/usr/bin/log` explicitly.

## Current interpretation

The broad IOHID `0xAF` probe is an informative negative result, not a successful activation. A
successful return from a one-byte feature write on an unrelated HID interface is insufficient
evidence that the remote received the Linux project's BLE-characteristic command. The exact mapping
between that GATT Report characteristic and macOS's exposed IOHID interfaces/report IDs remains the
main unknown.

The earlier “209-byte voice channel” description also needs to remain a hypothesis: enumeration
found a large report-shaped surface around feature report ID 255 (208 data bytes, or 209 including a
report-ID byte), while the device advertises a 209-byte maximum input report. Until a real varying
input stream is captured, it is not proven that feature ID 255 itself contains microphone audio.

### Gen-3 protocol correction

The newer, gen-3-specific [`azais-corentin/siri-remote`](https://github.com/azais-corentin/siri-remote)
implementation resolves several earlier unknowns:

- wire report `0xFA` is microphone audio with a 99-byte Opus payload;
- the stream is Opus CELT-only WB, TOC `0xB8`, 48 kHz mono, 20 ms / 960 samples per frame;
- `0xFB` is the two-byte system-button mask and `0xFC` is touch;
- the gen-3 firmware exposes Feature reports, not Output reports, for input enable;
- it writes `0xAF` to every writable non-Input Report characteristic because the HID service has
  multiple `0x2A4D` instances distinguished by Report Reference descriptors.

This matches the Mac's button report ID `0xFB`, and explains why probing Output IDs was ineffective.
macOS splits the same-UUID GATT reports into separate `IOHIDUserDevice` interfaces and rewrites the
large per-interface input/feature descriptor to report ID `0xFF`.

IORegistry identifies the likely audio route precisely:

- `bInterfaceNumber = 5`;
- primary usage `0x0C/0x04`;
- `AppleEmbeddedBluetoothAudio` is attached;
- input and feature report ID `0xFF`, 208 data bytes / 209 bytes with report ID;
- maximum output size is one byte, although no Output element is declared.

### Full-interface Feature activation run

The original matcher omitted the remote's two usage-page-`0x20` interfaces. Diagnostic mode now
matches all seven virtual interfaces and writes only the evidence-backed payload `[0xAF]` to each
declared Feature report `0xFF`.

Run at 2026-07-20 14:42 AEST:

- interfaces 0, 2, 4, 5 (audio), 6, and 7 accepted the Feature write;
- interface 1 (`0x0D/0x01`) returned `0xE00002BC` (`kIOReturnError`);
- raw input-report capture is registered on all seven interfaces;
- exactly one signed app instance was running with `--activate-mic`.

The user completed the physical trial at 14:44 AEST. The log captured Siri down at 14:44:09 and
Siri up at 14:44:17, confirming an approximately eight-second spoken trial, but it captured zero
raw voice reports. A post-trial IORegistry snapshot showed:

- the audio interface had `ReportAvailableCalls=0` and `ReportAvailableRuns=0`;
- HyperVibe's audio-interface client had `SetReportCnt=1` and `SetReportErrCnt=0`;
- the narrow unified-log query contained no audio-driver or remote-driver event during the trial.

This rules out a missed user action and a log-only filtering problem. The SetReport call was accepted
by IOHID, but no input notification reached the audio IOHID interface. It does not yet distinguish
between an activation that was accepted locally but not effective on GATT and an Apple driver path
that prevents the expected notification from reaching this interface.

For the next run, raw callback contexts now identify all seven interfaces and retain short reports,
so the Siri button packet itself can validate the callback path. The diagnostic also re-sends `[0xAF]`
to every declared Feature report immediately on Siri key-down, eliminating a stale activation after
remote sleep as the next variable. The rebuilt, stably signed instance started at 14:51 AEST.

### Second timed trial: callback and re-arm verified

The second trial ran from 14:53:42 to 14:53:52 AEST. It removed the remaining ambiguity in the
IOHID-level experiment:

- interface 2 delivered the expected raw `0xFB` button packets: `fb 20 00` on Siri-down and
  `fb 00 00` on release, so the raw callback mechanism is functioning;
- Siri-down triggered a same-second re-arm of all seven interfaces;
- the interface 5 audio Feature write again returned success;
- zero raw packets arrived from interface 5 during the ten-second spoken trial;
- IORegistry still reported zero report-available calls on interface 5, while HyperVibe's client
  recorded three successful Feature SetReport operations and no SetReport error.

This rules out a stale activation and a broken raw callback. Repeating the same IOHID write is no
longer useful without changing which layer owns or observes the audio Report characteristic.

### Public CoreBluetooth is blocked by system HID ownership

An opt-in, read-only `--dump-gatt <remote-name>` diagnostic was added. It first calls
`retrieveConnectedPeripherals` for HID service `0x1812`; if the target is absent, it performs a
20-second unfiltered scan but logs and connects only an exact-name match.

At 14:58 AEST, CoreBluetooth reported `poweredOn` and `allowedAlways`, but did not return the remote
as a connected HID peripheral and did not rediscover it while it remained connected to macOS. Thus
the public CoreBluetooth API cannot enumerate the system-owned HID Report characteristics in this
connection state. The Linux implementation documents the analogous ownership problem: BlueZ's HOGP
plugin must be disabled before userspace can address the eight same-UUID Report characteristics.

### Installed Apple driver: native PTT and audio sink

Inspection of the current system's `AppleBluetoothRemote` kernel-collection symbols, constant
strings, and x86_64 disassembly revealed two relevant paths:

1. `AppleEmbeddedBluetoothDeviceManagement::setPushToTalkPropertyWL` accepts registry property
   `PushToTalk`. For product IDs 788/789, it converts the value to one byte and attempts Feature
   report `0x99`. The diagnostic flag `--native-ptt` calls this driver property with an `OSNumber`-
   compatible `UInt8(1)` and registers raw callbacks on all seven interfaces first. On this Mac the
   call returned `0xE00002C7` (`kIOReturnUnsupported`), and no stream started.
2. `AppleEmbeddedBluetoothAudio::start` registers an interrupt-report callback on interface 5.
   `handleInterruptReport` validates the memory descriptor, copies at most 1024 bytes into a local
   stack buffer, and returns. It does not publish a CoreAudio device, enqueue data for a user client,
   or dispatch another event. This makes the Apple audio driver a likely exclusive sink for the
   mic reports that HyperVibe is trying to observe.

The upstream Linux implementation also makes an important operational point: report `0xFA` is
emitted only while the physical Siri button is held. Continuous music is useful as a changing test
signal after the stream opens, but it cannot replace the button/firmware gate by itself.

### Approved single-service detachment attempt

The user explicitly approved a recoverable driver-state experiment. Before mutation, IORegistry
showed exactly one `AppleEmbeddedBluetoothAudio` instance:

- registry ID `0x1000d5012`, active and `busy 0`;
- Product ID 789 and the tested remote's physical-device UUID;
- provider interface 5 (`0x0C/0x04`); the management service and six sibling interfaces were
  separate and remained out of scope.

`/usr/bin/kmutil unload --class-name AppleEmbeddedBluetoothAudio --verbose` is macOS's narrowest
user-space termination entry: it targets that IOService class without unloading the kext or removing
its personalities. The first non-root request reached `kernelmanagerd` but returned a remote error.
The same exact command was then run through the macOS administrator authorization dialog at
15:32:03 AEST. `kmutil` misleadingly exited zero, but both immediate and delayed IORegistry checks
showed the original service still active under the same registry ID; it was never detached or
rematched.

This outcome matches the platform policy. The service belongs to
`com.apple.driver.AppleBluetoothRemote`, and its Info.plist has no
`OSBundleAllowUserTerminate=true`. A RELEASE XNU kernel refuses class termination for protected
Apple kexts even when the caller is root. No recovery action was required because runtime state did
not change. Do not repeat the command or broaden it to the entire AppleBluetoothRemote bundle.

### Direct hidden-report PTT trial

`--direct-ptt` tests the remaining public IOHID distinction: perhaps the driver's registry-property
entry was blocked while the underlying hidden report remained writable. In this mode HyperVibe:

- opens all seven interfaces and registers raw-report callbacks;
- seizes only interface 5 audio, leaving the other six interfaces non-exclusive;
- re-sends `[0xAF]` to every declared Feature `0xFF`;
- sends report ID `0x99` with the one-byte body `[01]` only through management interface 0;
- automatically sends `[00]` 20 seconds later, with an additional cleanup release on normal exit.

The signed trial started at 15:45:39 AEST. At 15:45:41, six activation writes succeeded and the
digitizer write returned the known general error. Direct `0x99 [01]` returned
`0xE00002BC` (`kIOReturnError`) immediately; the timed `0x99 [00]` release returned the same error at
15:46:02. During the bounded window:

- no raw report arrived from interface 5;
- the provider remained at `ReportAvailableCalls=0` and `ReportAvailableRuns=0`;
- `AppleEmbeddedBluetoothAudio` stayed active with registry ID `0x1000d5012`;
- continuous music was present during activation, but that cannot matter after PTT itself fails.

The diagnostic then exited and no HyperVibe experiment process remained. This closes the public
IOHID PTT path: the exposed management device accepts its declared `0xFF [AF]` report, but it rejects
the driver's hidden report ID `0x99` from userspace.

After the experiment, exactly one no-argument HyperVibe instance was restored and its normal HID
enumeration succeeded. Future trials must preserve this invariant: replace the normal instance only
for the bounded diagnostic window, then restore it before considering the trial complete.

## Current boundary and agreed local-only scope

The failure is now below app-level callback, timing, sound, and ordinary administrator permission.
Repeating public IOHID writes, waiting for ambient noise, or trying more arbitrary report IDs will
not add evidence. Ambient music or white noise proves varying sample content only after the stream
is active; it is not a substitute for Siri hold or a successful PTT command.

The user has explicitly constrained further work to this Mac, its built-in Bluetooth controller,
and the currently paired remote. A separate Linux host, VM, external Bluetooth adapter, second
remote, and pairing changes are not part of the active plan. Linux remains useful only as protocol
evidence: it can disable BlueZ's `hog` owner and let userspace own the GATT reports, whereas macOS's
RELEASE kernel will not terminate the protected Apple service merely because the caller is root.

### Native HIDDriverKit replacement PoC — implementation complete, provisioning blocked

A separate local project now lives in [`driverkit/`](../driverkit/README.md). Its build and signing
workflow deliberately does not alter HyperVibe's signing or runtime:

- `SiriRemoteMicDriver` subclasses `IOUserHIDEventService` and overrides `handleReport` to log up to
  the complete 209-byte raw report as hexadecimal;
- its personality matches only vendor 76, product 789, and primary usage `0x0C/0x04`. That usage is
  the node previously enumerated as interface 5; the BLE `IOHIDInterface` itself does not publish a
  matchable `bInterfaceNumber` property;
- it uses the default match category with `IOProbeScore=8000`, above
  `AppleEmbeddedBluetoothAudio`'s observed score 7175, so an activated and rematched DEXT is a
  replacement experiment, not a passive tap. Registration alone does not prove that it owns the
  provider;
- after its superclass `Start` succeeds, the DEXT sends Feature report `0xFF [AF]` directly through
  its `IOHIDInterface` provider and logs the exact `IOReturn`. It keeps running if that write fails
  so ownership and activation failures remain separately observable;
- Xcode 26.6 successfully ran IIG, compiled, linked DriverKit + HIDDriverKit, and emitted an arm64
  DriverKit 25.5 shallow DEXT under `.build/driverkit/Products/Debug-driverkit/`;
- a programmatic AppKit host embeds the DEXT and submits only explicit activation/deactivation
  requests. The host is inert without a button click or `--activate`/`--deactivate` argument;
- version 2 of the DEXT and host built with warnings-as-errors, then both were signed inside-out
  using the local Apple Development identity. Both signatures have hardened-runtime flag `0x10000`,
  both resolve to TeamIdentifier `5S6YD5B7F4`, and strict nested verification succeeds.

The first signed launch at 16:53 AEST did not reach the System Extensions API. Both a no-argument
launch and an explicit `--activate` launch were killed before `main` with exit status 137. Unified
logs give the exact cause:

- `taskgated-helper`: `no eligible provisioning profiles found`;
- `amfid`: `AppleMobileFileIntegrityError Code=-413 "No matching profile found"`;
- kernel: the binary carries restricted entitlements but its signature could not be validated.

No `OSSystemExtensionRequest` was submitted, the DEXT was not registered, and
`systemextensionsctl list` remained unchanged. This result isolates the first gate to provisioning;
it says nothing yet about DEXT matching or microphone data.

Apple requires the DEXT's provisioning profile to contain
`com.apple.developer.driverkit`, `com.apple.developer.driverkit.transport.hid`, and
`com.apple.developer.driverkit.family.hid.eventservice`. The only local profile does not contain
them. The host separately requires `com.apple.developer.system-extension.install`. A development
certificate alone does not authorize either restricted entitlement set; administrator/root
permission is orthogonal to AMFI's profile validation.

With explicit user authorization, Xcode was then run with `-allowProvisioningUpdates` for the
signed TeamIdentifier `5S6YD5B7F4`. The request reached Apple's provisioning service but failed
before a profile was created: Xcode identifies this login as the Personal development team
`James Zhang`, which does not support DriverKit Transport HID, DriverKit Family HID EventService,
or DriverKit development capabilities. Thus automatic provisioning cannot unlock this DEXT from the
current free/personal team. This is an account-capability result, not a failure of the code, local
signing certificate, or administrator access.

After eligible profiles exist, the signed host must be copied as a complete bundle to
`/Applications` (or another recognized Applications directory) before it submits activation.
Running it from `.build` would otherwise introduce the separate
[`unsupportedParentBundleLocation`](https://developer.apple.com/documentation/systemextensions/ossystemextensionerror/unsupportedparentbundlelocation)
gate. During the actual activation/rematch window, normal HyperVibe must be stopped temporarily and
its interface-5 client verified absent; afterward exactly one normal instance must be restored.

The normal next gate is obtaining an Apple-granted DriverKit/HID profile. Apple documents a local
developer-security workflow while an entitlement request is pending, but evaluating or enabling
that route would change recovery/SIP security state and is a separate explicit decision; it has not
been performed. A read-only check reports `System Integrity Protection status: enabled`, and
`systemextensionsctl developer` refuses to change developer mode while SIP is enabled. Relevant
primary references are Apple's
[DriverKit entitlement process](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development),
[`IOUserHIDEventService`](https://developer.apple.com/documentation/HIDDriverKit/IOUserHIDEventService),
and [HID event-service sample](https://developer.apple.com/documentation/hiddriverkit/handling-keyboard-events-from-a-human-interface-device).

No further sound trial is useful until the DEXT can actually own interface 5. If that gate is
resolved, the next experiment is: verify ownership, confirm the DEXT's `0xFF [AF]` write result,
hold Siri for one bounded capture, then deactivate and confirm restoration of both the Apple service
and exactly one normal HyperVibe instance. Deactivation may be deferred until restart.

The macOS capture criterion is **not** a literal `0xFA` report ID. `0xFA` identifies the wire/GATT
microphone report in the upstream protocol; macOS splits that characteristic into interface 5 and
rewrites its local report ID to `0xFF`. Success is an interface-5 callback with local
`reportID=0xFF`, an expected-length varying payload, and plausible Opus content such as TOC `0xB8`.
Only a captured payload justifies Opus decoding and a virtual CoreAudio input.

### External macOS product claim — not independently verifiable

On 2026-07-20, public web research found CouchVox, whose site claims macOS 26 support for
second- and third-generation Siri Remotes, remote-microphone capture, a virtual microphone path,
and a restricted Bluetooth entitlement profile that must be reinstalled every three days. This is a
potentially relevant architectural lead because it describes a Bluetooth-entitlement route rather
than the DriverKit replacement route.

It is **not** evidence of a verified working implementation yet. Its advertised public download URL
`https://www.couchvox.com/releases/CouchVox.dmg` returned an HTML page rather than a disk image at
the time of inspection. No binary, Appcast feed, source repository, entitlement manifest, or
independent technical reproduction was found. Do not treat the claim as a successful macOS capture
case until an inspectable artifact or an independent reproduction is available.

The claimed route must also be distinguished from the public App Sandbox entitlement
`com.apple.security.device.bluetooth`. Apple documents that public boolean entitlement as ordinary
Bluetooth-device access configured in Xcode; it does not grant inspection of the system-owned HOGP
connection and does not require a three-day provisioning profile. Therefore CouchVox's claimed
"restricted Bluetooth entitlement" would have to be a separate, unnamed Apple-granted capability.
Apple's public signing guidance confirms that a genuinely restricted entitlement must be authorized
by an embedded provisioning profile, but no public Apple documentation corroborates this specific
Bluetooth entitlement or the asserted three-day lifetime. Without an inspectable CouchVox profile
or binary, its exact key and route remain unknown.

The changelog did expose a more concrete, independently plausible diagnostic lead. Version `0.0.5`
claims that remote capture depended on Apple's `PacketLogger`, whose original signature was broken
by notarization re-signing; version `0.0.2` mentions a remote-capture setup helper. Apple publicly
ships PacketLogger in Additional Tools for Xcode. Independent Bluetooth debugging documentation for
macOS 14.5+ says that Apple's `Bluetooth_macOS.mobileconfig` logging profile must be installed and
the Mac rebooted before PacketLogger can record Bluetooth traffic. This makes it plausible that the
site's "Bluetooth profile" refers to Apple's diagnostic logging profile rather than an entitlement
belonging to CouchVox itself. The actual Apple-signed profile downloaded in the local trial carries
`DurationUntilRemoval = 259200` (three days), so that lifetime is now verified—but it belongs to a
temporary **configuration profile**, not to an app provisioning profile or Bluetooth entitlement.
The CouchVox wording conflates those platform mechanisms.

This creates a useful local-only **observation** experiment: install Apple's logging profile and
PacketLogger, reproduce the existing `0xFF [AF]` / Siri-hold trial, and inspect the Bluetooth trace.
It neither activates microphone streaming by itself nor bypasses pairing or driver policy. It can,
however, establish whether the feature write leaves the Mac and whether the remote returns any
audio-shaped traffic while the Apple driver owns the interface. Because profile installation changes
system diagnostics configuration and requires a reboot, do not perform it without explicit approval.

#### PacketLogger/profile trial — profile installed but not accepted for live capture

On 2026-07-20, with explicit approval, the Mac downloaded Apple `Additional Tools for Xcode 26.6`
and a file named `Bluetooth_macOS.mobileconfig` from Apple's Profiles and Logs page. The DMG's
checksum structure verified and the profile decoded as Apple-signed, with a three-day removal
duration. The profile enables Bluetooth private-data, HCI trace, and raw-audio logging; it must be
treated as sensitive local diagnostic data and not exported without separate approval.

After installation and reboot, `profiles list` showed `com.apple.bluetooth.logging` installed for
the current user. However, `profiles show` identified it as **"Bluetooth Logging for iOS"**, with
description "Enables full logging for Bluetooth and WirelessProximity on iOS" and
`containsComputerItems: FALSE`. PacketLogger 26.6 launched and `bluetoothd` logged
`PacketLogger authenticated` followed by `Starting Live Logging` and then `Bluetooth Profile
Required`. Therefore this downloaded artifact is not accepted by the Mac's PacketLogger live-HCI
path on this system, despite its `Bluetooth_macOS.mobileconfig` filename and installed state. Do not
claim a PacketLogger HCI trace was captured; obtain an Apple profile that the daemon accepts before
using this route as evidence.

The Apple Profiles and Logs page source was then checked directly. Its sole entry named
"Bluetooth for macOS" points to the exact same path,
`/OS_X/OS_X_Logs/Bluetooth_macOS.mobileconfig`; no second public macOS Bluetooth profile is listed.
Its companion instructions PDF requires the Apple-account download session and could not be fetched
non-interactively. The current discrepancy is therefore an Apple-provided-profile/PacketLogger
compatibility issue on this Mac, not a missed platform filter or an alternate public artifact.

The same bounded observation trial did add lower-layer evidence. A temporary `--activate-mic`
instance registered all seven raw callbacks and submitted `0xFF [AF]` successfully through six
IOHID interfaces (one returned `0xE00002BC`). At the same timestamp, the Apple Bluetooth log showed
`BTLEServer` attempting the corresponding feature report and reporting `CBATTErrorDomain Code=130`
(`Unknown ATT error`) for the mapped lower report. Thus at least one request reached `bluetoothd`'s
HID-over-GATT path and was rejected remotely; the local `IOHIDDeviceSetReport` success code does not
prove that every write was accepted by the remote. No variable interface-5 audio payload appeared.
The diagnostic instance was stopped and exactly one normal no-argument HyperVibe instance restored.

By contrast, Remote Buddy's current support documentation explicitly supports the third-generation
remote's buttons and touch controls on macOS but says its microphone is unsupported. This remains
consistent with the completed public-HID negative experiments above.

## 2026-07-20 (evening): the gate is host authentication, not macOS

This session closed three whole classes of approach. The headline result is that **the remote's own
firmware refuses to enable the microphone for this Mac**, independently of driver ownership,
transport, and local privilege. The relevant experiments are recorded below in the order they were
run, because each one removes a variable the previous one could not.

### Relaxed platform security — a documented dead end

With explicit user approval, platform security was progressively relaxed on this Apple silicon Mac
(`Mac17,9`, macOS 26.5.1 build 25F80) specifically to load the self-signed DEXT:

1. `csrutil disable` in recoveryOS, then `systemextensionsctl developer on`. The signed host was
   still killed before `main` with exit status 137 (`SIGKILL`). Developer mode alone does not waive
   AMFI's provisioning check on the host's restricted
   `com.apple.developer.system-extension.install` entitlement.
2. `sudo nvram boot-args="amfi_get_out_of_my_way=1"` plus a reboot. The host then reached `main` for
   the first time and logged `Embedded DEXT found`. The activation request was submitted, macOS
   asked for approval under **General → Login Items & Extensions → Driver Extensions**, the user
   approved it, and `systemextensionsctl list` reported
   `com.hypervibe.SiriRemoteMicDriver (0.1/2) [activated enabled]`.

**The probe-score replacement strategy is confirmed correct.** With the DEXT enabled, the kernel
selected it over Apple's service for the audio provider:

```text
DK: SiriRemoteMicDriver-0x10000204d waiting for server com.hypervibe.SiriRemoteMicDriver-10000204d
```

The personality (`IOHIDInterface`, `IOProbeScore` 8000, VID 76, PID 789, usage `0x0C/0x04`) matches
the intended node. What fails is strictly the launch of the userspace driver server.

### The AMFI catch-22

The DEXT could never execute, and the two failure modes are mutually exclusive:

- **AMFI disabled** (`amfi_get_out_of_my_way=1`): `kernelmanagerd` reports
  `DextLaunch ... Error Domain=NSPOSIXErrorDomain Code=8 "Exec format error"` and
  `spawn failed, error=162: Codesigning issue`. No crash report is produced. DriverKit's own launch
  path depends on AMFI to establish the dext's code identity, so disabling AMFI breaks it.
- **AMFI enabled** (boot-arg removed, SIP still disabled, developer mode still on): the dext process
  spawns and is immediately killed. `/Library/Logs/DiagnosticReports/com.hypervibe.SiriRemoteMicDriver-*.ips`
  records `signal: SIGKILL (Code Signature Invalid)`,
  `termination: {namespace: CODESIGNING, indicator: "Taskgated Invalid Signature"}`, with
  `codeSigningID` and `codeSigningTeamID` both **empty** and `codeSigningTrustLevel = 4294967295`.
  The report also shows `sip: disabled`, `developerMode: 1`, and `codeSigningMonitor: 2`.

So AMFI must be present for a dext to launch, and AMFI will not accept restricted DriverKit
entitlements without an Apple-issued provisioning profile. `codeSigningMonitor: 2` indicates macOS 26
Apple silicon code-signing monitoring is active. **Do not spend further effort on boot-args or on
lowering to Permissive Security**: the experiments below show that even a perfectly loaded DEXT would
have observed nothing.

### Decisive experiment: userspace seizure of interface 5

The DriverKit effort existed to answer one question — *is Apple's driver consuming the microphone
reports before HyperVibe can see them?* That question was answered directly, without any DEXT, by
having HyperVibe itself seize the audio interface.

`--activate-mic` at 19:24 AEST:

- raw report callbacks registered on all seven BLE interfaces;
- `🔒 SEIZED HID device usage=0xC/0x4` — **HyperVibe owned interface 5; the Apple audio service was
  entirely out of the path**;
- `SetReport FEATURE id=0xFF bytes=[AF]` returned `0x0` on six interfaces, including interface 5;
  only interface 1 (`0x0D/0x01`) returned the known `0xE00002BC`;
- the user held Siri from 19:24:38 to 19:24:47 (about nine seconds) while speaking.

Result: **six raw frames total, every one of them from interface 2** (`fb 20 00` / button), and
**zero frames from interface 5**. No report longer than six bytes arrived on any interface.

This retires the exclusive-sink hypothesis recorded earlier in this document. Apple's driver was not
taking the frames; there were no frames.

### The firmware refuses the activation — explicit ATT rejection

`log show` had been silently useless in earlier sessions because the interactive shell aliases `log`;
use `/usr/bin/log` explicitly. With that fixed, `bluetoothd` shows the remote rejecting every
activation write, at each of the three attempts (initial arm, and the two Siri-down re-arms):

```text
BTLEServer: Error writing value for characteristic "Report" on peripheral "C08RQGMC2330":
            Error Domain=CBATTErrorDomain Code=130 "Unknown ATT error."
BTLEServer: Error setting feature report for ID #241: CBATTErrorDomain Code=130
```

ATT error `130` = `0x82`, inside the Bluetooth application-error range `0x80`–`0x9F`. This is not a
macOS transport failure: it is the remote's own HID service returning an application-defined refusal.
Note also that macOS maps the local `0xFF` feature write down to GATT report **ID 241 (`0xF1`)**.
`IOHIDDeviceSetReport` returning `kIOReturnSuccess` therefore only means IOHID accepted the request;
it does not mean the remote accepted it.

### USB transport experiment — activation accepted, still no audio

The remote was connected to the Mac over USB-C while remaining connected over BLE, giving a second,
independent command channel with no GATT layer.

USB enumeration (`Apple TV Remote`, `idVendor` 1452 / `0x05AC`, `idProduct` 789 / `0x0315`, serial
`C08RQGMC2330`, `bcdUSB` 512, `bNumConfigurations` 2, currently configuration 2) exposes only two
interfaces:

| interface | usage page / usage | maxInput | maxOutput | maxFeature |
|---|---|---|---|---|
| `Device Management@0` | `0xFF00` / `0x0B` | 1 | 1 | **25** |
| `Consumer Control@1` | `0x000C` / `0x01` | 3 | 1 | 1 |

**There is no `0x0C/0x04` audio interface over USB at all**, and no USB Audio class endpoint. The
209-byte audio surface exists only on the BLE side.

A dedicated probe opened the USB `0xFF00/0x0B` interface and inventoried its feature reports:

```text
GET feature id=0xFF len=1 -> ff              # the only report that exists
GET feature id=0x00/0x01/0x02/0x03/0x99/0xAF/0xF1 -> 0xE0005000   # not present
SET feature id=0xFF [af] -> 0x0 (success)    # accepted over USB
SET feature id=0x99 [01] -> 0xE0005000       # hidden PTT report does not exist on USB
```

So the gen-3 enable byte `0xAF` **is accepted on the USB control path**, where no ATT layer can
reject it — and the Apple driver's hidden `0x99` PushToTalk report simply does not exist there.

With the USB activation armed and BLE raw capture running, the user held Siri from 19:33:02 to
19:33:10 (about eight seconds) while speaking. Result: **zero frames on interface 5**; only the two
interface-2 button frames. Afterwards the USB device still exposed the same two interfaces, remained
on configuration 2, and published no new endpoint.

### What the three experiments do and do not prove

| # | configuration | audio frames |
|---|---|---|
| 1 | BLE, Apple's driver owning interface 5 | 0 |
| 2 | BLE, **HyperVibe seizing interface 5**, `0xAF` accepted by IOHID, rejected by firmware (ATT 130) | 0 |
| 3 | **USB activation accepted** (`0xFF [AF]` → success), BLE capture armed | 0 |

These **do** retire driver ownership, transport choice, and local privilege as explanations:
experiment 2 removed Apple's driver from the path entirely, and SIP/AMFI were disabled at various
points, all without changing the outcome.

They do **not** establish that the microphone is gated on host identity. An earlier revision of this
document concluded that; **that conclusion was wrong and is retracted.** The reason is in the next
section.

### Correction: the activation was almost certainly never addressed correctly

The upstream protocol is expressed in **raw GATT handles**, not in macOS HID report IDs. The
Linux-side description is explicit:

> To receive input data from the remote you need to send `0xAF` to the handle `0x001d`, and also
> enable notifications on handle `0x0022` by writing `0x01 0x00` to `0x0024`. You'll then receive
> byte arrays from `0x0023`.

Two consequences invalidate every activation attempt recorded in this document:

1. **We cannot address the required handle.** macOS does not expose GATT handles for a connected
   HOGP device. It splits the eight same-UUID `0x2A4D` Report characteristics into separate
   `IOHIDUserDevice` interfaces and **rewrites the report IDs**. The `bluetoothd` log proves the
   rewrite is happening and is not under our control: a local Feature write to report `0xFF` was
   mapped down to GATT report **ID 241 (`0xF1`)**. There is no evidence that `0xF1` corresponds to
   handle `0x001d`, and the ATT `130` refusal is therefore at least as consistent with *writing to
   the wrong characteristic* as with *being denied authorization*.
2. **We cannot control notification subscription.** The protocol requires an explicit CCCD write
   (`0x01 0x00`) to subscribe to the report characteristic that carries data. On macOS the system
   HOGP stack owns CCCD state. Even a correctly delivered enable byte would produce nothing
   observable if the system has not subscribed to the audio report characteristic.

There is also a reporting discrepancy worth noting: upstream describes writing `0xAF` to every
writable **Output** report characteristic, whereas this project's diagnostics wrote it to **Feature**
report `0xFF`. Earlier Output-report attempts in this repository failed with `0xE00002F0`, which is
itself consistent with the macOS abstraction not exposing the right target rather than with the
device rejecting the concept.

The USB result does not rescue the argument either. The USB `0xFF00/0x0B` interface is Apple's
generic device-management surface; it accepting a one-byte feature write says nothing about the
microphone, and USB publishes no audio endpoint at all, so there was never a path for audio to
arrive on that transport.

### Actual current boundary: macOS denies raw GATT for a connected HID device

The honest boundary is therefore **not** the remote's firmware. It is that speaking this protocol
requires raw GATT access — specific handles plus host-controlled CCCD subscription — and macOS
refuses to give userspace that access for a device its own HOGP stack owns. `--dump-gatt` already
demonstrated this directly: CoreBluetooth was `poweredOn` and `allowedAlways` but would not return
the connected remote as a peripheral.

This mirrors the Linux situation exactly, and the upstream projects solve it the same way: BlueZ's
`hog` plugin must be disabled so userspace owns the GATT characteristics, and `azais-corentin`'s
implementation bypasses its own BLE library to talk to `org.bluez.GattCharacteristic1` directly,
precisely because generic stacks collapse the eight same-UUID characteristics incorrectly.

### Raw GATT was then tested directly — macOS filters the HID service outright

The above avenue was pursued the same evening and produced a conclusive negative. The remote was
**unpaired** from macOS (Bluetooth → Forget This Device) and the USB cable removed, so the system
HOGP stack no longer owned it. A dedicated CoreBluetooth tool then scanned, found it, and connected
to it as an ordinary BLE peripheral:

```text
FOUND C08RQGMC2330 rssi=-57
   adv: kCBAdvDataServiceUUIDs: [ Human Interface Device ]   <-- device advertises HID
CONNECTED. discovering ALL services ...
explicitly requesting HID service 0x1812 ...
didDiscoverServices -> 2 service(s): 180A, 180F
   !!! HID service 0x1812 ABSENT !!!
```

The conditions could not be more favourable, and it still fails:

- the remote is **completely unpaired**; macOS's HID stack does not own it;
- **our process owns the CoreBluetooth connection**;
- the remote **advertises the HID service explicitly** in its advertisement data;
- both unfiltered `discoverServices(nil)` and an explicit `discoverServices([0x1812])` return only
  `180A` (Device Information) and `180F` (Battery).

**macOS's CoreBluetooth does not expose HID-over-GATT (`0x1812`) to third-party applications at
all.** This is a deliberate Apple platform restriction — it is what stops apps from snooping on or
injecting into Bluetooth keyboards and mice — and it applies regardless of pairing state or
connection ownership.

### Final boundary (supersedes all earlier interpretations)

Both, and only, routes by which macOS exposes this device are closed for this purpose:

| route | why it cannot reach the activation characteristic |
|---|---|
| **IOHID** (the only way macOS surfaces HID devices) | hides GATT handles, **rewrites report IDs** (local `0xFF` observed on the wire as report ID 241), and reserves CCCD/subscription state to the system stack |
| **CoreBluetooth** (the only public raw-GATT API) | **filters the `0x1812` HID service out entirely**, even when the app owns the connection to an unpaired peripheral |

There is therefore **no public-API path on macOS** to write the enable byte to the correct Report
characteristic or to subscribe to the audio characteristic. This is a platform capability that Apple
does not offer, not a permission, pairing, driver-ownership, entitlement, or firmware problem. Note
in particular that lowering platform security does not help: the restriction is in what the APIs
expose, not in what the caller is allowed to do.

Linux implementations succeed precisely because BlueZ permits disabling its `hog` plugin so that
userspace can own the GATT characteristics. macOS ships no equivalent switch.

**Consequently the only realistic remaining approach is a host or radio whose Bluetooth stack grants
raw GATT/HCI access to userspace** — a Linux host, a VM with a passed-through controller, or an
external BLE adapter driven directly. Those were previously declared out of scope for this project;
that scope decision now determines the outcome, because every in-scope avenue has been tested and
closed by evidence.

**Do not repeat:** boot-arg/AMFI/SIP variations, Permissive Security, DriverKit replacement,
probe-score tuning, driver unload, transport switching, unpairing, or CoreBluetooth discovery. All
are retired by direct experiment. Also do not claim the microphone is firmware- or pairing-locked:
that was never demonstrated, because no attempt on macOS was ever able to address the correct
characteristic in the first place.

### Restoration performed

The DEXT was uninstalled (`systemextensionsctl uninstall 5S6YD5B7F4 com.hypervibe.SiriRemoteMicDriver`
→ `Success`) because it cannot launch and generates a crash report on every boot. The
`amfi_get_out_of_my_way` boot-arg was removed (`sudo nvram -d boot-args`). Exactly one no-argument
`HyperVibe.app` instance is running. **SIP remains disabled and should be re-enabled** with
`csrutil enable` from recoveryOS; nothing in this investigation benefits from leaving it off.
