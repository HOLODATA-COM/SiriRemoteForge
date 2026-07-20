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
- HID interfaces (from `ioreg -r -c IOHIDDevice`): button interface uses **3-byte** input reports
  (usage page 0x0C, Consumer). There is a separate interface on **usage page 0x0D (Digitizer/Game)
  with `MaxInputReportSize = 209`** — a 209-byte input report is almost certainly the **voice/mic
  data channel**. Another interface is on page 0x20. The app seizes pages 0x0C/0x0D/0xFF00/0x01.

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

## Plan (what to try next)
1. **Prior art / protocol research.** People have reverse-engineered older Siri Remote voice
   (1st/2nd gen). Find: the BLE **voice GATT service/characteristics** (Apple has a proprietary
   "voice over HID/GATT"), the **activation command**, and the **audio codec** (candidates: Opus,
   or Apple's proprietary; older remotes used a specific format). Search terms: "Siri Remote voice
   reverse engineering", "AppleTV remote microphone BLE", "HID over GATT voice Apple remote".
2. **Enumerate the remote's control surface.** Dump all HID **feature/output reports** and, over BLE,
   the **GATT services + characteristics** (there is likely a vendor voice service). macOS: CoreBluetooth
   for GATT (needs a small tool), `IOHIDDeviceGetReport(kIOHIDReportTypeFeature, …)` for feature reports.
3. **Find & send the activation.** Try sending candidate **output/feature reports** (or GATT writes)
   to the remote and watch `/tmp/hypervibe.log` for `🎤 report` lines appearing. If the right write
   turns the stream on, we win step 1. (This may not even need the Siri button — the command itself
   may open the mic; the user only needs to make sound.)
4. **Decode the audio** → PCM (identify the codec from the byte patterns; the 209-byte frame size is
   a strong hint — e.g. a fixed Opus/ADPCM frame).
5. **Expose as an input device** — feed decoded PCM into a virtual CoreAudio input (BlackHole-style
   driver, or an AudioServerPlugIn) so the OS/voice-to-text can select "siriRemote Mic".

## Risks / unknowns
- The activation may be **pairing-bound / encrypted** (keys negotiated during Apple-TV pairing) →
  could be a hard wall. The remote is currently paired to this Mac as a plain BLE-HID device, not via
  the Apple-TV Siri handshake, so the voice service may be gated.
- The 209-byte report might be a feature report that never fires as input without activation.
- **Hardware-in-the-loop:** we can send commands programmatically, but confirming real audio needs the
  user to make sound near the remote. The activation attempt itself is scriptable.

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
