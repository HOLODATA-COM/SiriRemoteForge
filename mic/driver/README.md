# Siri Remote Mic — CoreAudio HAL virtual device (option B)

A virtual audio **input** device named "Siri Remote Mic" (manufacturer *Holodata.au*) intended for
explicit selection by apps. When a consumer opens it, the router feeds it decoded Siri Remote voice;
without a producer it returns silence. Built-in-microphone fallback is not implemented or required,
and this code does not alter the built-in device.

This is the "own device" path (B), not reusing BlackHole at runtime. **BlackHole is used only as the
implementation base** — it is a proven, GPL-3.0 AudioServerPlugIn that loads on macOS 26, so we build
on it rather than hand-writing ~2000 lines of fiddly CoreAudio boilerplate from scratch.

## Attribution / license

`vendor/BlackHole.c` and `vendor/BlackHole-LICENSE.txt` are **pristine, unmodified** BlackHole
(© 2019–2026 Existential Audio Inc., GPL-3.0). The fork is `SiriRemoteMic.c`; product configuration
is isolated in `SiriRemoteMic.config.h`, injected with `clang -include`, so the upstream source stays
re-syncable. This whole repo is GPL-3.0, so incorporating GPL-3.0 code is clean; add the BlackHole
copyright to `NOTICE` when this integrates. Do not commit BlackHole's icon or branding.

## Build / install / remove

```sh
./build.sh       # local bundle + process-local contract test; safe, no coreaudiod contact
./install.sh     # FAIL-CLOSED; system use requires explicit acknowledgements and separate approval
./uninstall.sh   # remove it + restart coreaudiod
```

The plug-in needs no external runtime dependency — pure Apple CoreAudio. (The *capture* side of the
pipeline still needs libopus + PacketLogger; that is separate from this device.)

## Status

- **VALIDATED ON THE REAL HOST (2026-07-23, post-fix).** The fixed bundle was installed under an
  auto-rollback watchdog (rm + `killall coreaudiod` on any sustained `coreaudiod` ≥85%). Both prior
  storm paths are now clean: **load/reconciliation** settled to idle within ~2 s (a one-sample 87%
  transient is normal `coreaudiod` restart, not the storm), and **client-open IO** peaked at only
  **6%** (the earlier incident hit 100%+). A CoreAudio consumer opened the device and received
  **147,456 non-silent samples** from the test producer (`PASS — shared-memory audio reached a
  CoreAudio consumer`). The device is mono/48 k/input-only and did **not** hijack the default input
  (built-in mic remained default; `kCanBeDefaultDevice=false` held). `coreaudiod` idle ~3% after.
- **System state:** the fixed bundle is currently **installed** at `/Library/Audio/Plug-Ins/HAL/` and
  stable. `./uninstall.sh` removes it. It produces safe silence when no producer is feeding the ring.
- **The earlier storm (for history):** a test of the *unfixed* bundle drove `coreaudiod` over 100% CPU
  and needed a reboot; that is what motivated the 10 HAL fixes below. It is fixed, not merely avoided.
- **Mechanism proven:** the shared-memory IPC transport (also independently 144,384 samples earlier).
- **Revised HAL offline PASS:** one static 48 kHz mono input device; no Box, mirror device, output
  stream or missing icon; default-device eligibility disabled. UID translation, timestamps, every
  published property, exact buffer sizes/canaries, no-producer silence and 20,000 reconciliation
  cycles pass in a fake-host process. ASan and UBSan also pass.
- **Router offline PASS:** the real 3,071-line trace yields 804/804 decoded frames, 771,840 samples,
  RMS 3232.3, peak 32767, no decode errors.
- **Blocked:** no post-fix real-host test, no built-in fallback, no full clock-drift correction and no
  shipping-app integration.

`install.sh` intentionally requires an explicit system-audio risk token, refuses to overwrite an
installed bundle, and separately refuses while the stale preferred UID remains. Do not bypass these
gates without a newly approved, bounded test and a rollback watchdog.

## Config surface (`SiriRemoteMic.config.h`)

`kDevice_Name` "Siri Remote Mic" · `kManufacturer_Name` "Holodata.au" · `kPlugIn_BundleID`
au.holodata.SiriRemoteMic · `kDriver_Name` "SiriRemoteMic" · `kHas_Driver_Name_Format` 0 (no "2ch"
suffix). Factory UUID (Info.plist) `75E269CD-FD8C-457E-B1A9-BDEED64F001F`, freshly generated so it can
never collide with a BlackHole install; it maps to the pristine `BlackHole_Create` factory symbol.

Safety overrides also set `kPlugIn_HasBox=false`, `kPlugIn_HasDevice2=false`,
`kDevice_HasIcon=false`, `kCanBeDefaultDevice=false` and
`kCanBeDefaultSystemDevice=false`.
