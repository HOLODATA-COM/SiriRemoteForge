# SiriRemoteForge — living handoff

Last updated: 2026-07-20 (Australia/Sydney)

This document is the concise source of truth for continuing development. Keep it updated whenever
the architecture, user-facing mappings, build/run workflow, or microphone investigation changes.
The detailed product and configuration reference remains in `README.md`; microphone experiments
belong in `docs/mic-reverse-engineering.md`.

## Repository and runtime state

- Canonical repository: `https://github.com/HOLODATA-COM/SiriRemoteForge`, branch `main`.
- Local checkout: `/Users/zhangwenqian/siriremote-release`.
- Current committed HEAD: `b70754c` (`docs: living doc for the Siri Remote mic reverse-engineering`).
- `app/RemoteInputHandler.swift` currently has intentional, uncommitted microphone diagnostics
  (`--dump-reports`, `--activate-mic`, `--native-ptt`, and `--direct-ptt`). Do not discard or
  overwrite them.
- `driverkit/` contains an intentional, uncommitted `SiriRemoteMicDriver` DEXT plus a separate
  activation host. Both compile and development-sign, but neither has been installed or activated.
- Active user configuration: `~/.config/siriremote/config.jsonc` (hot-reloaded; intentionally not in
  git). A representative copy is `examples/config.jsonc`.
- Runtime log: `/tmp/hypervibe.log`.
- Built artifacts are under `app/` and are git-ignored: `HyperVibe`, `HyperVibe.app`, and generated
  icon files.

## Architecture

The project is a native macOS menu-bar controller for a 3rd-generation USB-C Siri Remote.

1. `RemoteDetector` finds and seizes the remote's HID interfaces.
2. `RemoteInputHandler` identifies physical buttons and implements tap/double/hold/repeat/layer
   semantics.
3. `TouchHandler` reads the clickpad through the private `MultitouchSupport` framework and produces
   cursor movement, taps, swipes, shake-to-find, and circular scrolling.
4. `SiriRemoteCore` loads JSONC, resolves app modes and layers, and dispatches typed actions.
5. `MacActionExecutor` performs keystrokes, media keys, shell commands, AppleScript, app launches,
   mouse actions, Space changes, and display brightness changes.
6. `AppWatcher` maps the frontmost app to a configured mode.
7. SwiftUI settings provide tuning and a drawn, clickable remote mapping editor.

`SiriRemoteCore/` is dependency-free SwiftPM code with unit tests. `app/` is compiled directly with
`swiftc`; the core sources are compiled into the same executable.

## Implemented behavior

- Remappable click-ring directions and physical buttons.
- Trackpad cursor with nonlinear acceleration, dead-zone, press freeze, click/drag, and tap-to-click.
- Outer-ring circular scrolling and swipe/two-finger-tap recognition.
- Per-app profiles with inheritance.
- Layer × app composition; a layer button supports both sticky tap-to-toggle and momentary hold.
  A layer is a MODIFIER, not a second keyboard — see "Layer resolution" below.
- macOS-style HUD when a layer is enabled or disabled.
- Hold-progress HUD: while a button with hold bindings is held, a card shows a filling track, a tick
  per bound stage, and the name/icon of the action that runs if released now. Stage 0 shows the
  ordinary tap, because releasing early fires it — it is a choice, not a cancel.
- Double-tap disambiguation, three release-to-select hold stages, and synthetic hold-to-repeat.
- Animated Space switching through BetterTouchTool action IDs 113/114 where configured.
- Cursor shake highlight.
- Power-button mapping that lowers display brightness; subsequent remote activity restores it.
- **Power-button sleep/lock suppression.** macOS also translates the remote's Power button
  (Consumer `0x0C/0x30`) into the *system* power-button hotkey; `loginwindow`'s `HotKeyManager`
  acts on it (`PBSleepsMachine:1` → "power button sleeps the machine"), so a bound Power button
  used to run our action **and** lock the Mac. Seizing the HID device does not prevent this — the
  hotkey path is separate. `MediaKeyInterceptor` now swallows the three `NX_SYSDEFINED` events one
  press emits (`subtype=1`; `subtype=8`/`NX_POWER_KEY` down and up) via `onPowerKey`, using the
  same "from our remote **and** bound in config" rule as media keys — which is what keeps the
  Mac's own physical power button working. The window is measured from
  `RemoteInputHandler.lastPowerEventTime`, stamped on **press and release**: `lastProcessedTime`
  is press-only, so on a long press it expired mid-hold and the key-**UP** leaked — and key-UP is
  precisely the event loginwindow sleeps on. Do not add logging inside the tap callback; a slow
  callback gets the tap disabled by the system, silently restoring the lock behaviour.
- Native Tuning and Layout settings tabs; edits round-trip to the JSONC config.
- **Device panel** (`app/DeviceInfo.swift`, shown at the top of the Tuning tab and as a battery
  readout in the header pill): battery %, firmware revision, Bluetooth address, serial,
  vendor/product, and an expandable list of the seven HID interfaces. Battery/firmware/address are
  parsed from `system_profiler -json SPBluetoothDataType` on a background queue (the remote does not
  publish an IORegistry `BatteryPercent`, unlike Magic Trackpad/Keyboard, so this is the only
  source); the interface map comes from `IOHIDManager`. Refreshes every 60 s, on window appear, and
  whenever connection state changes. `app/tools/remote-info.sh` reports the same data from the shell
  (`--battery` prints just the percentage).

The current personal mapping is defined by `~/.config/siriremote/config.jsonc`. Important points:

- TV button toggles `L1`.
- Siri button sends the right-side Ctrl+Cmd+Option chord; double Siri sends Enter.
- Global ring directions send arrow keys; double ring-left/right use BTT to switch Spaces.
- Browser base ring-left/right switch tabs; in L1 they become plain arrows.
- Terminal Back repeats Delete while held.
- Music uses AppleScript for previous/next, play/pause, and mute.


### Layer resolution

While layer `L` is held, key `K` resolves most-specific-first:

1. `"L.K"` in the active app mode's `inherits` chain — this app, in this layer.
2. `"K"` among mode `L`'s **own** bindings — any app, in this layer.
3. `"K"` in the active app mode's `inherits` chain — this app, **without** the layer.

Step 3 is why holding a layer never deadens a bound key. It was added after holding `L1` in a
terminal left the Back button doing nothing: `terminal` binds it to `repeatKey delete`, `global`
binds it not at all, and resolution used to fall back through the LAYER mode's `inherits` chain —
which lands on `global`, never on the app's own binding.

Step 2 deliberately does not walk mode `L`'s `inherits`. Layer modes are written as
`"L1": { "inherits": "global" }`, so following it would answer with `global`'s base binding and
shadow step 3's app-specific one — the original bug.

There is no fourth step for "any app, without the layer". Steps 1 and 3 walk the *app* mode's
`inherits` chain, and that is what reaches `global`. Keeping it there rather than hard-wiring a
global fallback is what lets a mode opt out: a mode with no `inherits` is standalone and sees
nothing else, layered or not. All four cells of the app × layer matrix are pinned by tests in
`ControllerTests`.

`Controller.site(_:)` returns the action and its presentation together, so a label/icon can never be
taken from a different binding that merely shares the key.

### Presentation (`label` / `icon`)

Display-only keys on any binding, used by the hold-progress HUD. Resolution order in
`ActionVisual`: config `label`/`icon` → the real app icon for an action that OPENS an app (`launch`,
`shell` of the form `open -a "X"`; shown alone, without a label) → the real app icon for an action
AIMED at an app (`applescript` containing `tell application "X"`; shown beside the label) → an SF
Symbol per action kind.

Presentation inherits down the mode chain **independently of the binding, field by field**. A key
keeps its identity even where a mode re-binds it, so `label`/`icon` are set once in `global` and an
app mode that overrides only the action still shows the same name and icon. This was a bug fix:
Play/Pause showed a generic AppleScript scroll icon whenever Apple Music was frontmost, because the
`music` mode re-binds that button and presentation used to stop at the mode owning the binding.

HUD icon geometry is measured, not assumed: the icon is centred on the label's cap-height box using
AppKit's own `firstBaselineOffsetFromTop` (reconstructing the line box from ascender/descender put
it visibly low), and sized by HEIGHT with the width following the image's aspect ratio (symbols are
not square — `playpause.fill` is 40x22, and fitting it into a square box rendered it at half the
height of a square symbol). `--test-hold-hud` holds each stage far longer than the real thresholds
so it can actually be screenshotted; app launch latency makes the real ones unhittable.

## Build and run

```sh
cd /Users/zhangwenqian/siriremote-release/SiriRemoteCore
swift test

cd /Users/zhangwenqian/siriremote-release/app
./build.sh
./create_app_bundle.sh
open HyperVibe.app
```

The App requires Accessibility and Input Monitoring permissions. It is deliberately signed without
the hardened runtime because the private MultitouchSupport callback is incompatible with it. This,
the private frameworks, HID seizure, global synthetic input, shell execution, and AppleScript make
the project unsuitable for the Mac App Store. Developer ID signing and notarized direct distribution
remain possible.

Runtime invariant: keep exactly one normal `HyperVibe.app` instance running whenever no diagnostic
trial is active. A hardware trial may temporarily replace it with one flagged instance, but the
trial is not finished until that process is stopped, a no-argument app instance is relaunched, and
the process list plus HID-enumeration log confirm it is running. Never leave zero or duplicate app
instances; duplicates compete for seized HID interfaces.

## Microphone investigation — current truth

Goal: activate and read the Siri Remote's built-in microphone on macOS, decode it, and eventually
expose it as an audio input.

Confirmed:

- The remote is BLE/HID only and does not advertise a standard Bluetooth audio profile or CoreAudio
  input device.
- Raw capture with `--capture-mic` works for registering an input-report callback.
- Holding Siri without a host activation command produced no large reports.
- HID enumeration found a large report-shaped surface around report ID 255 (208 data bytes; 209 when
  a report-ID byte is included), but its exact role as an input voice stream is not yet proven.
- A current Linux implementation for the 3rd-generation remote identifies wire input report `0xFA`
  as microphone audio: a 99-byte Opus payload (CELT-only WB, 48 kHz mono, 20 ms / 960 samples). It
  writes byte `0xAF` to every writable non-Input HID Report characteristic. Its source notes that
  this generation exposes Feature reports rather than Output reports.

Latest diagnostic experiment (2026-07-20):

- Added `--dump-reports` to enumerate input/output/feature elements, sizes, report IDs, and readable
  feature reports.
- Added `--activate-mic` to register raw capture and probe candidate HID report IDs with `0xAF`.
- All candidate HID output writes returned `0xE00002F0`.
- One-byte feature writes on several non-digitizer interfaces returned success, including report ID
  255, but this is not evidence that the intended BLE characteristic was reached.
- On the likely digitizer interface (primary usage page `0x0D`), candidate feature writes returned
  `0xE00002BC`; the padded 208-byte report-ID-255 write also failed.
- Post-write reads on the digitizer interface returned feature 0 = `00 01` and feature 1 =
  `01 db 00 49 00`.
- No `🎤 report` voice frames appeared after the activation attempt. Therefore the microphone is
  still not activated and no codec conclusion is justified yet.

Follow-up protocol correction and controlled run (2026-07-20):

- macOS IORegistry exposes seven virtual interfaces for the remote. The likely audio path is
  `bInterfaceNumber=5`, usage `0x0C/0x04`, with `AppleEmbeddedBluetoothAudio` attached. macOS
  rewrites the per-characteristic report to ID `0xFF`, maximum input/feature size 209 bytes.
- The diagnostic matcher originally omitted two usage-page-`0x20` interfaces. Diagnostic mode now
  includes them, while normal app mode remains unchanged.
- The activation implementation now writes only `[0xAF]` to declared Feature report `0xFF` on all
  seven interfaces, matching the gen-3 Linux implementation rather than scanning arbitrary IDs.
- Six Feature writes returned success. Interface 1 (`0x0D/0x01`) returned general I/O error; this is
  acceptable if it is a read-only input characteristic. The audio interface write succeeded.
- The first post-correction physical trial ran from 14:44:09 to 14:44:17 AEST: the Siri press and
  release were captured, the user spoke for about eight seconds, and zero raw voice reports arrived.
- After that trial, IORegistry showed `ReportAvailableCalls=0` and `ReportAvailableRuns=0` on the
  audio IOHID interface. HyperVibe's client showed `SetReportCnt=1` and `SetReportErrCnt=0`. This
  proves that IOHID accepted the Feature write but received no input notification on that interface.
- The diagnostic now labels raw reports by interface, logs short reports as well as large reports,
  and re-sends the evidence-backed activation to all seven interfaces immediately on Siri key-down.
  A newly built, stably signed `--activate-mic` instance started at 14:51 AEST.
- The second physical trial ran from 14:53:42 to 14:53:52 AEST. Raw capture saw the Siri/button
  interface's `0xFB` packets (`fb 20 00` down, `fb 00 00` up), proving that the raw callback path
  works. Siri-down immediately re-armed all seven interfaces; the audio Feature write succeeded;
  still no audio-interface report arrived. The audio interface remained at zero report-available
  calls while its HyperVibe client showed three successful SetReport calls.
- A read-only `--dump-gatt <name>` CoreBluetooth diagnostic was added and run. Authorization was
  `allowedAlways`, but macOS returned no connected HID peripheral and the already-connected remote
  did not advertise during an unfiltered exact-name scan. Public CoreBluetooth therefore cannot
  reach the system-owned HID service in its current paired/connected state.
- Reverse-engineering the installed `AppleBluetoothRemote` kernel collection found a native
  `PushToTalk` property. For product IDs 788/789 its handler attempts a one-byte hidden Feature
  report `0x99`. The opt-in `--native-ptt` diagnostic invoked that exact property path, but the
  current system returned `0xE00002C7` (`kIOReturnUnsupported`) and no stream began.
- The same driver inspection shows `AppleEmbeddedBluetoothAudio::start` registering an interrupt
  report callback. Its `handleInterruptReport` copies at most 1024 bytes into a stack buffer and
  returns without publishing a CoreAudio device or user event. This installed Apple driver is thus
  a likely exclusive sink for mic reports, not an audio source implementation.
- With explicit approval, the narrowest driver-state command was tested both normally and through
  macOS administrator authorization: `kmutil unload --class-name AppleEmbeddedBluetoothAudio`.
  Before the request there was exactly one instance (`0x1000d5012`); afterward that same instance
  remained active. The Apple kext lacks `OSBundleAllowUserTerminate`, so RELEASE XNU protects it
  even from root. No service was detached and no recovery was needed.
- Added bounded `--direct-ptt`: it opens all seven interfaces, seizes only interface 5 audio,
  re-arms declared Feature `0xFF` reports with `[0xAF]`, sends hidden Feature `0x99 [01]` through
  management interface 0, and automatically sends `[00]` after 20 seconds. The signed 15:45 AEST
  trial returned `0xE00002BC` for both `[01]` and `[00]`, received no interface-5 report, and left
  `ReportAvailableCalls/Runs` at zero. The experiment process was then stopped.

Important caution: the current probe writes `0xAF` only to the declared Feature report on each of the
seven interfaces, mirroring the gen-3 Linux implementation. Direct `0x99` and protected-driver
termination are now evidence-backed negative results; do not repeat them, broaden termination to the
entire AppleBluetoothRemote bundle, resume arbitrary report-ID scans, or change pairing state.

Agreed debugging scope: use only this Mac, its built-in Bluetooth controller, and the currently
paired remote. The user has explicitly ruled out a separate Linux host, VM, external Bluetooth
adapter, second remote, and pairing changes. Do not offer those again as the active plan.

Native DriverKit status:

- Added `driverkit/SiriRemoteMicDriver.xcodeproj`, a single-target HIDDriverKit DEXT. It subclasses
  `IOUserHIDEventService`, logs up to all 209 raw report bytes, and matches only VID 76 / PID 789 /
  usage `0x0C/0x04`, the IORegistry node previously enumerated as interface 5. The BLE
  `IOHIDInterface` provider does not itself publish `bInterfaceNumber`, so the personality does not
  pretend to match on that unavailable property.
- Its default-category `IOProbeScore=8000` is intentionally above the installed Apple audio
  service's score 7175. Once activated and rematched, it is intended to replace that service; mere
  registration does not prove ownership, so IORegistry verification is mandatory.
- On successful `Start`, the DEXT sends Feature report `0xFF [AF]` through its `IOHIDInterface`
  provider and logs the exact `IOReturn` before registering. This removes the earlier ambiguity in
  which a replacement driver could own the interface but never arm the microphone.
- `driverkit/build-host.sh` completed successfully with Xcode 26.6 and DriverKit SDK 25.5. It emits
  the arm64 DEXT and a separate host under `.build/driverkit/Products/Debug/`. Version 2 of both
  targets compiles with warnings-as-errors.
- Both bundles were signed inside-out with the local Apple Development identity, hardened runtime
  is present on both (`flags=0x10000(runtime)`), TeamIdentifier is `5S6YD5B7F4`, and strict nested
  signature verification passes.
- `driverkit/sign-host-development.sh` accepts either the identity alone for structural signing or
  the identity plus separate host/DEXT profile paths; in the latter mode it validates and embeds
  both profiles before the inside-out signing pass.
- The first signed host launch was a real negative test of provisioning, not DEXT activation. AMFI
  killed it before `main` with `AppleMobileFileIntegrityError Code=-413` / `No matching profile
  found`; `taskgated-helper` reported no eligible provisioning profiles. Therefore no
  `OSSystemExtensionRequest` ran and `systemextensionsctl list` was unchanged.
- The missing authorization covers the DEXT's DriverKit/HID entitlements and the host's
  `com.apple.developer.system-extension.install` entitlement. Administrator/root access does not
  waive profile validation. Once profiles exist, the host must also be copied from `.build` to
  `/Applications` before activation to satisfy the parent-bundle-location rule.
- With explicit user authorization, `xcodebuild -allowProvisioningUpdates` contacted Apple's
  provisioning service for TeamIdentifier `5S6YD5B7F4`. Xcode rejected the request before any local
  profile was created: the logged-in Personal development team (`James Zhang`) does not support
  DriverKit Transport HID, DriverKit Family HID EventService, or DriverKit development capabilities.
  The normal automatic-provisioning path is therefore unavailable to this team.

Resolved on 2026-07-20 (evening) — the DriverKit and local-privilege routes are closed:

- SIP was disabled and `amfi_get_out_of_my_way=1` set, which did let the host run and the DEXT reach
  `[activated enabled]`. IOKit **selected** the DEXT for the audio provider, proving the probe-score
  strategy (8000 > 7175) is sound.
- The DEXT nevertheless can never launch. AMFI-off breaks DriverKit's own exec path (`ENOEXEC`);
  AMFI-on kills the dext with `CODESIGNING` / `Taskgated Invalid Signature` because its restricted
  entitlements have no Apple-issued profile. These two requirements are mutually exclusive, so
  Permissive Security and further boot-arg work are pointless.
- The DEXT has been uninstalled and the boot-arg removed. **SIP is still disabled; re-enable it with
  `csrutil enable` from recoveryOS.**

More importantly, the DriverKit question turned out to be the wrong question. HyperVibe itself
**seized interface 5**, removing Apple's driver from the path entirely, and a ~9 s Siri hold still
produced **zero audio frames** — so nothing was ever being intercepted. A USB-C session (activation
byte accepted over USB, no audio interface exposed on USB) produced zero frames as well.

Corrected conclusion — do not repeat the earlier claim that the microphone is firmware/pairing
locked; that is **not** supported by the evidence. The upstream protocol is defined over **raw GATT
handles** (`0xAF` → handle `0x001d`, CCCD `0x01 0x00` → handle `0x0024`, data from `0x0023`), while
macOS exposes neither handles nor CCCD control and demonstrably **rewrites report IDs** (a local
`0xFF` Feature write appeared on the wire as GATT report ID 241). No attempt so far is known to have
reached the correct characteristic, and the ATT `130` refusals are as consistent with a wrong target
as with a denial.

That raw-GATT avenue was then tested the same evening and is also closed. With the remote
**unpaired** and the USB cable removed — so macOS's HID stack did not own it — a CoreBluetooth tool
connected to it directly as an ordinary BLE peripheral. macOS still refused to expose the HID
service: both `discoverServices(nil)` and an explicit `discoverServices([0x1812])` returned only
`180A` (Device Information) and `180F` (Battery), despite the remote advertising HID in its
advertisement data.

**Final conclusion: there is no public-API path on macOS to reach the activation characteristic.**
IOHID hides GATT handles, rewrites report IDs, and reserves CCCD state to the system; CoreBluetooth
filters the `0x1812` HID service out entirely for third-party apps regardless of pairing state or
connection ownership. This is a platform capability Apple does not offer — not a permission,
pairing, entitlement, driver-ownership, or firmware problem — and lowering platform security does
not affect it. Linux implementations work only because BlueZ lets userspace take over GATT by
disabling its `hog` plugin; macOS has no equivalent.

The only realistic remaining approach is a host or radio granting raw GATT/HCI access to userspace
(Linux host, VM with a passed-through controller, or an external BLE adapter). That was declared out
of scope for this project, and that scope decision now determines the outcome. **The microphone
investigation is closed on macOS.**

Diagnostic note: the interactive shell aliases `log`; several sessions' log queries silently returned
nothing. Always invoke `/usr/bin/log`.

See `docs/mic-reverse-engineering.md` for the experiment log and evidence.

External-case audit: CouchVox publicly claims Siri Remote microphone capture on macOS 26 through a
restricted Bluetooth-entitlement path, but its advertised DMG URL returned HTML during inspection
and no inspectable binary/source/independent reproduction was found. Treat it only as an unverified
lead, not as a demonstrated alternative to the current DriverKit experiment. Do not confuse the
claim with the public App Sandbox Bluetooth entitlement: the latter is ordinary device access and
does not authorize inspection of macOS's system-owned HOGP connection.

PacketLogger diagnostic lead: CouchVox's static changelog names Apple's PacketLogger as its remote
capture dependency. Apple distributes PacketLogger through Additional Tools for Xcode; independent
macOS Bluetooth debugging guidance requires Apple's `Bluetooth_macOS.mobileconfig` logging profile
and a reboot before PacketLogger can record traffic. This may explain the claimed short-lived
"Bluetooth profile" without proving any private CouchVox entitlement. If explicitly approved, use
that official diagnostic path only to observe the existing `0xFF [AF]` / Siri-hold experiment; it
does not itself activate the mic or change pairing.

PacketLogger trial result (2026-07-20): Apple Additional Tools for Xcode 26.6 and the downloaded
`Bluetooth_macOS.mobileconfig` were verified, installed, and followed by a reboot. The profile is
present as `com.apple.bluetooth.logging`, but `profiles show` calls it "Bluetooth Logging for iOS"
and reports `containsComputerItems: FALSE`. PacketLogger authenticated, tried to start live logging,
then `bluetoothd` reported `Bluetooth Profile Required`; no valid HCI trace was obtained. Treat the
downloaded artifact as unsuitable for Mac live capture until Apple supplies a profile that
`bluetoothd` accepts. The paired remote's temporary `--activate-mic` trial nevertheless reached
Apple's `BTLEServer`; one mapped feature-report attempt was rejected with ATT error 130. Restore
state complete: one normal no-argument HyperVibe instance is running.

Apple page follow-up: its sole public "Bluetooth for macOS" entry links to the exact same
`/OS_X/OS_X_Logs/Bluetooth_macOS.mobileconfig` file already tested. No alternative public macOS
Bluetooth profile is listed. The companion instructions PDF is Apple-account-gated and was not
available to non-interactive retrieval.

## Open issue — brightness does not come back the next morning

**Status: unresolved, waiting on a reproduction with logging in place. Do not clear
`/tmp/hypervibe.log` — it is accumulating on purpose.**

Symptom, reported 2026-07-21: the Power button is used to dim all displays before bed; the next
morning neither pressing a button nor touching the trackpad brings the brightness back.

Established so far:

- Both input paths fail, so this is **not** input detection alone.
- All displays support brightness control and all dim together, so it is not a
  main-display-vs-other-display mismatch (an early theory, ruled out by the user).
- The app does not crash overnight and is still running; no crash reports.
- The Mac never sleeps: `OnlySwitch` holds a `NoDisplaySleepAssertion` and `caffeinate` prevents
  idle sleep, so the display stays *on* at zero brightness all night — an unusual state.
- The remote itself sleeps after a few minutes idle. The user's hypothesis is that the overnight
  disconnect is what breaks it; untested.

**Very likely root cause, found 2026-07-21 and fixed — awaiting an overnight confirmation.**

`mainValue()` read `CGMainDisplayID()`, and on this Mac the main display is an external panel that
`DisplayServicesGetBrightness` refuses:

```
CGMainDisplayID() = 2
display 2 ★MAIN  builtin=false  read=FAILED (1000)
display 1        builtin=true   read=1.000
display 5        builtin=false   read=1.000
```

So the read failed **every** time, silently. With the original `?? false` that meant the live-read
fallback never fired at all: restoring depended entirely on the in-memory `isDimmed` flag, and any
path that lost the flag left the screen dark with no way back from the remote.

The same root cause produced the opposite bug when "fixed" from the wrong end: failing *open* on a
nil read meant every button press and every touch decided "dimmed" and ramped brightness up. Both
directions are wrong; the read itself had to be fixed.

`mainValue()` now walks the active display list — built-in first, then externals — and returns the
first display that answers. Driving brightness with synthesized keys moves every display together,
so any responsive display is representative. Failure handling is back to fail-closed.

Also in place:

- Reconnecting the remote calls `restoreIfDimmed()` directly, so waking the remote is enough and it
  does not depend on which input arrives first or on the trackpad having re-attached.
- Rate-limited diagnostic: `💡 restoreIfDimmed: isDimmed=? measured=? → RESTORE/declined`. The
  `measured` field used to be permanently `nil` on this Mac; it now shows a real number.

**Still unverified:** whether the morning symptom is actually gone. Test after a night with the
screen dimmed. If it recurs, **do not restart the app first** — read the log. The remaining
untested possibility is that the restore runs but the synthesized brightness keys have no effect in
that state, which the log will show as `→ RESTORE` with the screen still dark.

## Maintenance rules

- Preserve user changes and the active config; do not reset or replace mappings without explicit
  permission.
- After source changes: run core tests, build the app, package it, relaunch it, and inspect the log.
- After every diagnostic: restore exactly one no-argument HyperVibe instance and verify that it is
  running. Do not end a debugging session while the app is stopped or duplicated.
- Keep experiments behind command-line flags and off by default.
- Record exact commands, IOReturn values, report IDs/sizes, and whether the user completed the
  physical Siri-button step. Do not upgrade hypotheses to facts without captured data.
- Update this file and the relevant detailed document before ending an investigation session.
