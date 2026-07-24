# Voice pipeline (WIP — reproducing the Siri Remote mic on pure macOS)

**Status: offline pipeline green; the HAL virtual device is now VALIDATED on the real host
(2026-07-23, post-fix) — installed, stable, audio flows, no storm; not yet wired to the live router
or integrated into the shipping app.** This directory is the staging
area for reproducing — in our own code — the microphone path that the dissected `RemotePilot.app`
uses (see HANDOFF "Microphone — SOLVED on macOS (2026-07-23)"). It builds independently of the main
app so the app's green build is never at risk until the whole pipeline is validated.

The goal: expose one system-wide **Siri Remote Mic** input device. While Siri is held it carries the
remote's voice. Inactive behavior is currently silence. Built-in-microphone fallback is only a
future option and is not required by the implementation; no built-in-microphone setting or driver
has been changed. Pure Mac, no ESP32 or private entitlement.

## The pipeline

```
① enable HCI logging   defaults write /Library/Preferences/com.apple.MobileBluetooth.debug \
   (needs admin,          HCITraces -dict …HCISkipAuth,RawAudioTrace,HIDTrace… ; killall -30 bluetoothd
    reversible)         ← the step that defeats the "Bluetooth Profile Required" wall
② capture HCI          packetlogger convert            (live → .pklg file, or -s to stdout)
③ extract voice        packetlogger audio -i cap.pklg  OR hand-parse the -f nhdr stream for report 0xFA
④ Opus → PCM           OpusVoiceDecoder                (continuous PCM — required for a live device)
⑤ virtual mic device   own CoreAudio HAL plugin        ("Siri Remote Mic"; silence when inactive)
```

## Output stage — DECIDED: option B, our own virtual microphone (2026-07-23)

Not speech-to-text-injection. The output is a **system-wide virtual input device** named "Siri Remote
Mic" that shows up in every app's mic picker (Zoom, QuickTime, Voice Memos, and macOS Dictation — which
subsumes the "type what I say" feature: just point Dictation at this device). Chosen over reusing
BlackHole because we want one branded device with the fallback built in, not a visible router app.

- **Tech: a CoreAudio `AudioServerPlugIn` (HAL plugin)** installed to `/Library/Audio/Plug-Ins/HAL/`,
  loaded by `coreaudiod`. This is the BlackHole/Loopback mechanism. Crucially it is **userspace and
  needs no DriverKit entitlement/provisioning** — the exact wall that killed the earlier
  `SiriRemoteMicDriver` DEXT (personal team lacks DriverKit HID). Ad-hoc signing works for a local
  install; BlackHole is the proof-of-pattern.
- **Fallback remains undecided and unimplemented.** The safe current behavior is silence when the
  remote is inactive. A later mixer may read the built-in mic normally through AVAudioEngine only
  while demanded, but it must never alter that device's driver, format or default setting.
- **IPC**: the plugin runs inside `coreaudiod`, our capture app runs separately, so decoded PCM crosses
  to the plugin over a lock-free **POSIX shared-memory ring buffer** (`/SiriRemoteMicAudio`).
- **Demand detection**: the router observes CoreAudio's
  `kAudioDevicePropertyDeviceIsRunningSomewhere` property. It does not need the plug-in to write a
  reverse IPC flag. This was verified against System Settings opening/closing the device.

### The new hard problem this stage introduces — a jitter buffer

Unlike speech-to-text (Speech.framework tolerates bursty `append`), a **live audio device is pulled by
a steady clock** while BLE voice frames arrive in ~60 Hz bursts. Without a **jitter/ring buffer + clock
matching**, the device glitches and drops out. This is standard VoIP practice but it is real DSP work —
budget for it; it is the main engineering risk of choosing B over A.

### System-install safety boundary

An installed test on 2026-07-23 caused a CoreAudio property-notification/reconciliation storm:
`coreaudiod` exceeded 100% CPU and the Mac became nearly unusable. The plug-in was removed; a reboot
cleared the storm. The plug-in is currently **not installed**. The system audio preference plist
still records `SiriRemoteMic_UID` as preferred input index 0 and has intentionally not been edited.

**Post-fix system validation now PASSED (2026-07-23).** The fixed bundle was installed under an
auto-rollback watchdog (auto-uninstall on `coreaudiod` ≥85% sustained). Load reconciliation settled to
idle in ~2 s; the client-open IO path — what stormed before — peaked at only **6%**; a CoreAudio
consumer received 147,456 non-silent samples through the shared ring; the device did not become the
default input. The bundle is currently installed and stable (`coreaudiod` ~3% idle). The earlier storm
is fixed, not merely avoided. `install.sh` remains fail-closed by default; the recommended install path
is `mic/driver/install-watchdog.sh`, which installs and then auto-uninstalls if `coreaudiod` storms.

- The virtual device is a **persistent system component** (admin to install, `killall coreaudiod` to
  load — brief audio interruption machine-wide, survives reboot). Not install-per-use.
- No future system test should occur without a separate explicit user decision, an automatic
  rollback/watchdog, a bounded duration and independent `coreaudiod` monitoring.

### Current build order

The real-capture parser/decoder/router and the process-local HAL contract are green. Remaining order:
clock-drift/jitter hardening → safe system validation on a disposable/test Mac → live PacketLogger
pipe → optional inactive-source policy → integration into the main app. Built-in fallback is not a
prerequisite; silence is acceptable.

## What is DONE and validated (2026-07-23, offline)

- **③/④ codec path — `OpusVoiceDecoder.swift`.** Decode-only wrapper over Homebrew libopus 1.6.1.
  Validated by an encode→decode round-trip (`test_decoder.swift`, run via `./build-test.sh`):
  960 samples out, non-silent, plus concealment, a Speech-ready `AVAudioPCMBuffer`, and a WAV dump.
  The remote's frames are CELT-only **wideband (16 kHz), 20 ms, TOC 0xb8**; the decoder is created at
  48 kHz and libopus upsamples internally, so output is 960 samples/frame ready for Speech.framework.
- **PacketLogger CLI reconnaissance** (the `packetlogger` binary from Additional Tools 26.6, present at
  `/Applications/PacketLogger.app/Contents/Resources/packetlogger`):
  - `convert -o FILE.pklg` with no `-i` **captures live** to a pklg; `-s` streams to stdout.
  - `-f nhdr` columns = `timestamp · name · connection-handle · direction · raw-bytes` — the exact
    shape a live parser wants. (RemotePilot uses `convert -s -f nhdr`.)
  - **`audio -i FILE.pklg -o DIR -f <freq>`** extracts voice audio from an HCI trace directly — so the
    fiddly HCI/ATT reassembly of stage ③ may be done for us by Apple's own tool for file-based runs.

## Spike — FULLY CONFIRMED, end to end (2026-07-23)

**The entire input pipeline is proven and audibly verified.** The user held the Siri button and spoke;
we captured, parsed, decoded, and played back their voice — they confirmed it is clearly them.
Definitive GO. Concretely, from one live capture:
- The remote (`E0:C3:EA:A3:03:4D`) connected on handle `0x0406`; holding Siri produced a burst of
  ~111-byte packets — **877 RECV packets** in the window.
- **804 voice frames** were extracted (~16.1 s = 50 frames/s = 20 ms/frame) and **all 804 decoded
  cleanly through `OpusVoiceDecoder` (0 errors)**, RMS 3232 (non-silent). WAV written and played back;
  user: "很清楚" (crystal clear).

**Exact voice-frame format — the reference for the live parser (verified against 804 real frames):**
- Voice = an **ATT Handle-Value-Notification (opcode `0x1B`) on attribute handle `0x0035`**, arriving
  on the remote's ACL connection handle (dynamic; was `0x0406` this session). Filter signature in the
  raw bytes: `04 00 1B 35 00` (L2CAP CID 0x0004 = ATT, opcode 0x1B, handle 0x0035).
- ATT value layout: `[4-byte sequence/header][1-byte Opus length L][Opus frame of L bytes]`, the Opus
  frame beginning with **TOC `0xB8`** (CELT-only wideband, 20 ms).
- Decode each frame at 48 kHz mono → 960 samples. ~50 fps.
- **No enable-write needed:** with the remote paired to macOS normally (HyperVibe just running), holding
  Siri makes the stream flow on its own; we only sniff. `packetlogger audio` does NOT extract these
  (it doesn't recognize this GATT voice), so our own parse + OpusVoiceDecoder is the path.

Reproduce offline from a capture: `tmp/decode_voice.py` (ctypes → libopus) parses `mic_raw.txt` and
writes a WAV. That script + `OpusVoiceDecoder.swift` together are stages ②–④, now validated on real data.

## Virtual device — mechanism proven, system integration blocked (2026-07-23)

- An earlier bounded test proved the shared-memory mechanism end to end:
  **144,384 samples, RMS 0.162295, peak 0.25**, against source RMS 0.178589.
- A later installed-device test caused the severe CoreAudio storm described above. Therefore the
  old “M2 COMPLETE” label was wrong; the device is not production-safe and is not installed.
- Confirmed offline fixes include the input-only timestamp anchor, UID qualifier checks, static
  one-device/no-Box object graph, rejection of inherited hidden/output objects, property-size
  correctness, mono/input-only capability reporting and clock-control mutability.
- `srm_driver_contract_test.c` loads the bundle in-process with a fake host and validates every
  published property using canaries, I/O timestamps and silence, plus 20,000 stable reconciliation
  loops with zero notifications. Optimized, ASan and UBSan runs pass.
- `srm_capture_test.c`, `srm_test_writer.c` and `srm_usage_monitor.c` remain diagnostic tools, not
  evidence that the revised bundle has been safely loaded by the real CoreAudio host.

### How the mechanism was first confirmed (2026-07-23, earlier)

With the user's admin password, an unattended, fully-reversible probe (`tmp/hci_capture_probe.sh`) did
steps ①–② without the Siri hold:
- `defaults write …com.apple.MobileBluetooth.debug HCITraces -dict …HCISkipAuth,RawAudioTrace,HIDTrace…`
  wrote a proper boolean dict (verified by read-back), `killall -30 bluetoothd` reloaded it, and
  `packetlogger convert -o cap.pklg` produced a **non-empty 15 KB HCI trace → 219 decoded lines**.
  On 2026-07-20 the equivalent step got `bluetoothd: "Bluetooth Profile Required"` and nothing; the
  debug-defaults path (not the iOS `.mobileconfig`) is confirmed to be the way in.
- The `-f nhdr` line shape is now seen for real: `timestamp · name · handle · direction · raw-hex`
  (e.g. advertising reports, the Magic Trackpad on handle 0x0001) — this is what the live parser reads.
- Cleanup verified: debug domain deleted (it did not pre-exist), bluetoothd reloaded, exactly one
  no-argument HyperVibe instance still running. System returned to its prior state.

## Build dependency

`brew install opus` (BSD-licensed, GPL-3.0-compatible). Headers/lib resolved via `brew --prefix opus`
in `build-test.sh`; the main app's `build.sh` will gain `-I…/include -L…/lib -lopus` only when the
pipeline is integrated.

## Caveats (why this is a hack, carried from HANDOFF)

Needs admin; depends on Apple's PacketLogger and on undocumented debug prefs that any OS update can
change; restarting bluetoothd briefly drops all BT. It is privileged HCI capture of your OWN paired
remote on your OWN Mac — fine personally, not something to ship to others without thought.
