# SiriRemoteForge — living handoff

Last updated: 2026-07-23 (Australia/Sydney)

This document is the concise source of truth for continuing development. Keep it updated whenever
the architecture, user-facing mappings, build/run workflow, or microphone investigation changes.
The detailed product and configuration reference remains in `README.md`; microphone experiments
belong in `docs/mic-reverse-engineering.md`.

## Repository and runtime state

- Canonical repository: `https://github.com/HOLODATA-COM/SiriRemoteForge`, branch `main`.
  **GPL-3.0-or-later** as of 2026-07-22, going public; the paid-release plan was dropped. Upstream's
  MIT notice is retained in `NOTICE` — see the licensing note at the end for why that is mandatory.
- Local checkout: the repository root (`siriremote-release`).
- Current committed HEAD: `3f1b017` (`feat(mic): clean real-time streaming — fragment reassembly + lock-free jitter buffer`).

### ⚡ LATEST — 2026-07-24: virtual-mic productionization + push-to-talk (read git log too)

Most of the mic work below (items 1–4) is now DONE + committed. Current head-of-line state, newest first:

- **Virtual-mic PRODUCTIONIZATION (making it a real, always-usable system mic):**
  - `3579b15` plug-in broadcasts a Darwin notification `au.holodata.SiriRemoteMic.consumers` on
    StartIO/StopIO (device-in-use demand signal; validated it crosses coreaudiod's sandbox).
  - `6e18d0d` **root LaunchDaemon `srm_captured`** (`mic/captured/`) watches that demand and runs
    PacketLogger + srm_router ONLY while an app uses the device — auto-capture, no per-use sudo.
    Installed + running: `mic/captured/install.sh` (system LaunchDaemon at
    `/Library/LaunchDaemons/au.holodata.SiriRemoteMic.captured.plist`, binaries in
    `/Library/Application Support/SiriRemoteMic/`). Teardown is SIGKILL + async SIGCHLD reap (a
    blocking waitpid on the main queue had hung it — fixed). Log: `/var/log/srm_captured.log`.
  - `68237ed` + `9980605` GUI-picker visibility fixes: the device advertised
    `CanBeDefaultDevice=false` (apps that list only default-eligible mics, e.g. Typeless, hid it) and
    transport `Virtual` (apps that exclude virtual devices hid it). Now `CanBeDefaultDevice=true` and
    transport `USB`. Both live-confirmed (System Settings + Typeless now show it).
  - `a1639bc` **built-in-mic FALLBACK in the plug-in (Phase 2a):** ReadInput serves the remote ring
    while fresh (writeIndex advanced within 150 ms = Siri held) and falls back to a second ring
    `/SiriRemoteMicBuiltin` when stale, with a 5 ms timeline-anchored crossfade; both reads
    position-based/idempotent. **Phase 2b (IN PROGRESS, fable):** HyperVibe captures the BUILT-IN mic
    (explicitly, NOT the default input — else feedback if the default is our own device) and writes
    that ring, demand-gated on the same notification, needs `NSMicrophoneUsageDescription` + a TCC
    prompt. When 2b lands: select "Siri Remote Mic" anywhere → built-in mic normally, hold Siri → remote.
  - TCC gotcha for testing: `ffmpeg -f avfoundation` needs the TERMINAL (Warp) to hold Microphone
    permission. Reinstall dance for the plug-in: `sudo rm -rf …HAL/SiriRemoteMic.driver
    && sudo cp -R … && sudo killall coreaudiod`. Offline sims use an `SRM_IPC_SUFFIX` env seam (private shm +
    notify namespace) so the live daemon can't clobber them; coreaudiod never sets it.

- **Siri-button PUSH-TO-TALK for dictation (Typeless)** — `7978ecf`/`098d8c7`/`976161f`. `button.siri`
  is a new `pushToTalk` action: hold >=0.2 s → fire the hotkey (`rctrl+rcmd+ropt`, Typeless toggle on),
  release → fire it again (off); a quick brush (<0.2 s) does nothing; two quick taps → the `.double`
  binding (Enter). Coexists cleanly — the 0.2 s activation delay separates "held" from "two quick taps".
  Config: `~/.config/siriremote/config.jsonc` `button.siri` + `button.siri.double`.

- **Input feel** — `d2656d4`: tap-then-hold no longer leaks its tap; held-key repeat reads
  `KeyRepeat`/`InitialKeyRepeat` from the user's NSGlobalDomain AND uses a `.strict` main-queue timer
  (a plain main-queue timer fires ~36 ms/uneven, not the 15 ms set → felt slow+choppy). **User-set
  tuning knobs live in the config**: `doubleTapWindow=0.2` (single-tap on a `.double` key waits this),
  `holdThreshold=0.5`/`1.0`/`1.6` for `.hold`/`.hold2`/`.hold3` (release-to-select). User has DECLINED
  making arrow keys instant (they keep their `.hold`/`.double` bindings and the inherent tap delay).
- **HUD** — `c3e156a`: GPU Metal water HUD (user confirmed smooth).

### ⚡ In-flight session state — 2026-07-23 evening (context compacted here; READ THIS FIRST)

Four threads open, most changes UNCOMMITTED in the working tree. A background **fable** agent was still
rewriting the water HUD when this was written. Repo is PRIVATE now.

1. **Virtual-mic DEVICE audio bug — FIXED, INSTALLED & LIVE-CONFIRMED (2026-07-23).** The fixed
   (position-based) plug-in is installed at `/Library/Audio/Plug-Ins/HAL/SiriRemoteMic.driver`
   (byte-identical to the build), watchdog-install was STABLE (a 232 % coreaudiod blip at restart is
   the normal HAL reload, not a storm — settled to 0 %), and the user did the live capture holding Siri:
   **clean audible voice from the "Siri Remote Mic" device** ("现在能听到了，没什么问题"); a faint pop
   was physical wind (no windscreen), consistent with the analysis (`full-scale=0`, `discontinuities=0`).
   TCC gotcha for whoever reruns the live test: `ffmpeg -f avfoundation` fails with "Cannot use Siri
   Remote Mic" if the TERMINAL app lacks Microphone permission — this user's `dev.warp.Warp-Stable` was
   `auth=0` (denied) in `~/Library/.../TCC.db`; enabling Warp's mic (or using the already-permitted
   `au.holodata.SiriRemoteMicCaptureTest.app`, auth=2) fixes it. HCI voice-capture defaults get cleared
   on reboot — re-set them with the `defaults write …MobileBluetooth.debug` block + `killall -30
   bluetoothd`. Root cause recap: the plug-in `ReadInput` used a *sequential* cursor (`gSRM_ReadIndex++`);
   Apple's AudioServerPlugIn contract requires a *position-based* read keyed to `mInputTime`
   (idempotent, re-readable). Any second reader or IO resync double-drained the ring → speech chopped
   to "only faint breath" + time-compressed ("plays fast": ~3.9 s captured for a 16 s window). Fable
   rewrote ReadInput position-based, dropped `kSRM_InputGain` to **1.0** (the decoded source genuinely
   hits full scale — the clipping was ours), added `mic/driver/srm_io_sim.c` (offline regression gate:
   unfixed = 128 splices / 182-of-182 mismatched re-reads; fixed = 0 / 0) and
   `mic/driver/live_device_test.sh`. **The INSTALLED bundle is still the OLD broken build** (my
   sequential-cursor + gain-1.5) — the fix is only in source. To validate:
   `cd mic/driver && ./build.sh && ./uninstall.sh; ./install-watchdog.sh && ./live_device_test.sh`
   then hold Siri; expect `full-scale≈0`, `LOOKS CLEAN`, duration ≈ 15 s, and playback matching the
   monitor. (The in-process `--monitor` ear path was already clean & committed — thread 4; THIS is the
   OTHER path, the HAL device other apps consume.)

2. **taphold first-tap leak — FIXED & DEPLOYED** (`app/RemoteInputHandler.swift`, uncommitted; running
   HyperVibe PID ~65403). First a note: "taphold doesn't work" originally = the RUNNING app was a STALE
   **Jul-21 `.app` bundle** — ALWAYS `./create_app_bundle.sh` after `./build.sh`, the bundle binary is
   separate from `app/HyperVibe`. THE HARD PART is a genuine physical conflict on the Back key (delete +
   taphold menu): at the instant of a press the system cannot know if it will become "hold→repeat-delete"
   (wants instant) or "tap→then-hold→menu" (must NOT fire delete) — they're identical for the first
   ~100 ms. So instant-delete ⇒ taphold leaks; defer-to-be-safe ⇒ delete lags. Iteration: (a) deferred
   the tap by full `doubleTapWindow` → plain-hold delete lagged 300 ms → user: unacceptable; (b) reverted
   to instant → user: taphold must NOT leak; (c) user chose *keep menu on Back, accept some delay*.
   **Current shipped design — "defer only the QUICK TAP, never the HOLD":** a `.taphold*` key does not
   fire on press (`handleTapPress` skips it when `hasAnyHoldStage(.taphold)`); instead the held-key repeat
   is armed with a SHORT onset `tapholdHoldOnset = 0.13 s` (vs `autoRepeatDelay` 0.3 s) so a PLAIN HOLD
   fires its first delete at ~130 ms then repeats continuously; a QUICK tap (released < 130 ms) never
   engages the repeat, so `handleTapRelease` DEFERS it by `doubleTapWindow` and a following taphold press
   cancels it (`pendingTap.cancel()` in the `isTapholdCandidate` branch). The `heldKeyEngaged` flag (set
   when the repeat engages, checked in `handleTapRelease`) stops a hold from ALSO firing the deferred tap.
   RESIDUAL COST: a single tap-delete still lands ~0.3 s after release (the taphold-detection window) —
   tunable by shortening the window if the user dislikes it. **Known edge (unaddressed):** a rapid
   DOUBLE-tap of Back is read as tap-then-hold (HUD flash + one delete dropped) because the cancel fires
   on ARM not on stage-FIRE; only bites if the user double-taps to delete.
   **2b. Held-key repeat RATE fix (same commit, deployed PID ~73402):** the held-key mechanism was always
   a TRUE hold — `Keys.holdBegin` presses the key down, `Keys.holdRepeat` re-posts it with
   `kCGKeyboardEventAutorepeat=1` (identical to a real keyboard), `holdEnd` lifts it — NOT discrete
   re-tapping. But the interval was hard-coded `autoRepeatInterval = 0.06 s` (16.7/s) while THIS user's
   keyboard is set to the fastest (`KeyRepeat=1` → 15 ms/67ps, `InitialKeyRepeat=15` → 225 ms), so held
   Delete / arrow-repeat felt 4× too slow and "choppy" (you could see each event). Fix: read the user's
   own `KeyRepeat`/`InitialKeyRepeat` from NSGlobalDomain via `CFPreferencesCopyAppValue(…,
   kCFPreferencesAnyApplication)` (15 ms per stored tick), map to `keystrokeRepeatInterval` (held
   keystrokes: Delete, arrows) and `autoRepeatDelay` (initial delay), floored against runaway. MEDIA/volume
   kept on the old slow `autoRepeatInterval = 0.06 s` (each tick steps one notch; 67/s would fly). Read once
   at init — a mid-session keyboard-settings change needs an app restart.
   **2c. Repeat timer PRECISION (the actual "slower + choppy" cause — same commit, deployed PID ~85769):**
   after 2b matched the rate, held keys STILL felt slower AND uneven than the keyboard on BOTH delete and
   cursor. Measured it: a `DispatchSource.makeTimerSource(queue: .main)` at 15 ms actually fires at **avg
   36 ms (28/s), spiking to 74 ms** — macOS COALESCES/DEFERS main-queue dispatch timers for power, so no
   interval value alone can fix it. Standalone harness (`$CLAUDE_JOB_DIR/tmp/timer_test*.swift`): default
   main = 36 ms/wild; `.strict` on main = **15.00 ms, sd 0.73 ms, 67/s** (one-line fix, no concurrency
   change); dedicated `.userInteractive` queue + `.strict` = 15.00 ms, sd 0.13 ms (smoothest, but needs
   the timer moved off-main → races on `buttonState`/`heldRepeatKeys`/`heldKeyEngaged`, deferred). SHIPPED
   the safe one: `makeTimerSource(flags: .strict, queue: .main)` + 0.1 ms leeway on the keystroke repeat
   timer in `startHeldKeyRepeat`. If the user still feels micro-jitter, escalate to the dedicated-queue
   version (careful concurrency refactor, or hand to fable). **Awaiting user test.** Fable's GPU HUD:
   user tested it — "挺流畅，没什么问题".

3. **Water HUD high-performance rewrite — fable IN PROGRESS** on `app/HoldProgressHUD.swift` (target:
   GPU/Metal or CADisplayLink, zero main-thread jank, SAME visuals + public interface). NOTE the HUD was
   NOT the lag the user hit — that was Chrome at ~100 % CPU (since closed) plus this session's background
   agents; the HUD idles at 0 % and its sum-of-sines is ~560 `sin`/frame (trivial). User wants the
   rewrite regardless. When fable finishes: `cd app && ./build.sh && ./create_app_bundle.sh` then restart
   HyperVibe — that ALSO ships the taphold fix already built in.

4. **Real-time streaming ear-monitor — DONE & COMMITTED** (`3f1b017`): the "streaming drops half the
   frames" mystery was NOT PacketLogger — the ~99 B voice notification arrives as TWO ACL fragments on
   the live wire and the old parser dropped first-fragments. Fix: L2CAP reassembly (`PklgTailReader.swift`)
   + lock-free jitter buffer (`MonitorAudioRing.c`). `mic/router/live_monitor.sh` is a clean, real-time,
   user-confirmed monitor. This unblocked everything above.

Uncommitted: `app/RemoteInputHandler.swift` (taphold); `mic/driver/{SiriRemoteMic.c, build.sh, srm_io_sim.c,
live_device_test.sh}` (fable device fix); incoming `app/HoldProgressHUD.swift` (fable HUD). The `.app`
bundle is rebuilt with taphold. Nothing here is committed yet — decide per-thread after the user validates.
- Diagnostics live behind flags and ARE committed: `--dump-reports`, `--activate-mic`,
  `--native-ptt`, `--direct-ptt`, `--dump-gatt`, `--capture-mic`, `--dump-touches`, `--dump-z`,
  `--dump-press`, `--touch-monitor`, and the visual QC flags `--test-hold-hud`, `--test-layer-hud`,
  `--test-connect-hud`, `--test-drag-badge`, `--test-app-wheel`, `--snapshot-layout`,
  `--test-highlight`. All are off by default.
- `driverkit/` contains a `SiriRemoteMicDriver` DEXT plus a separate activation host. Both compile
  and development-sign; neither has been installed or activated, and the microphone work they were
  for is closed (see below).
- Active user configuration: `~/.config/siriremote/config.jsonc` (hot-reloaded; intentionally not in
  git). A representative copy is `examples/config.jsonc`.
- Runtime log: `/tmp/hypervibe.log`. APPEND to it (`>>`); it accumulates across runs on purpose.
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
- Multi-tap (`.double`/`.triple`), release-to-select hold stages, a cancel position, a SECOND hold
  menu via tap-then-hold (`.taphold*`), and true held-key auto-repeat. Load-bearing timing details:
  - The double-tap window is measured from the first RELEASE to the second press, not press to
    press. Held-longer first taps used to eat into the window, so how fast you had to tap the second
    time depended on how long you held the first.
  - Each hold binding may carry its own delay (`"after": 1.2`), overriding the global
    `holdThreshold`/`2`/`3`. **Stages are ordered by effective delay, not by the `.hold`/`.hold2`/
    `.hold3` suffix** — the suffix is only a name, and `.hold3` may fire first.
  - `holdCancelGrace` seconds past a key's DEEPEST bound stage, releasing fires nothing. Shown on
    the card as a final position, because a hidden escape hatch is no escape hatch. It only reaches
    keys with hold bindings: `.repeatKey` returns before stages are armed, which is right — its
    repeats already happened and there is nothing pending to take back.
  - **`.taphold*` is a SECOND hold menu, reached by tap → then press-and-hold.** It reuses the exact
    release-to-select machinery and the progress HUD; only the binding suffix differs, so
    `armHoldStages(family:)` and `holdStageKey(_:_:_:)` are parameterised over `.hold*` vs
    `.taphold*`. Detection is a timestamp: `lastTapTime` is set on every tap release, and a press
    landing within `doubleTapWindow` on a key that has a `.taphold*` binding is the hold half (see
    `isTapholdCandidate`). Because it only fires on the SECOND press, and a key without `.triple`
    resolves its double on the second-press RELEASE, tap-then-hold adds NO latency to keys that don't
    also bind `.triple`. `.taphold*` deliberately does NOT count in `hasAnyHoldStage(_:family:.hold)`,
    so a key with only `.taphold` still auto-repeats on a plain (first-press) hold — which is exactly
    how the Back button now gets tap=Delete, plain-hold=repeat-Delete, tap-then-hold=close/quit menu.
  - **Auto-repeat is a TRUE held key, not rapid re-tapping.** `Keys.holdBegin/holdRepeat/holdEnd`
    keep the key physically down and post repeats with `kCGKeyboardEventAutorepeat=1`, so the host
    treats it like a real keyboard (selection extension, games, autorepeat-flag checks all behave).
    The only teardown that lifts a held key is `stopKeyRepeat`; every teardown path funnels there, or
    the key sticks down. Media keys keep the OLD discrete re-tap on purpose — each press steps volume
    one notch, so "repeating" a media key means stepping, not holding.
  - **`autoRepeatDelay` is decoupled from `holdThreshold`** (now a standalone `0.3s`, a keyboard-like
    "delay until repeat"). Auto-repeat only happens on keys with no `.hold*` menu, so there is no
    hold stage to race and it can start sooner than the hold threshold with no conflict. It was tied
    to `holdThreshold` (0.5s) for conceptual unity, which just made a held key sluggish to start.
- Animated Space switching via System Events (needs Automation permission). No third-party tool —
  see "Settled — Space switching" below for the three routes measured and why only this one works.
- Cursor shake highlight.
- **Sticky drag** on Select. Holding it past 0.5 s picks the item up and keeps the mouse button
  down after the remote button AND the finger are released; the next Select press drops it. A badge
  pinned beside the pointer says so for the duration — the hold card has faded by then, so nothing
  else would show the mouse is still down, and being silently in a drag is worse than not having it.
  This REPLACED drag-while-held, which was removed. A tiered design (short hold = ordinary drag,
  long hold = sticky) cannot work: dragging involves moving, moving takes a second or two, so every
  ordinary drag would cross the deeper threshold anyway.
- **Full screen** is an action (`{"action": "fullscreen"}`), not a keystroke. Synthesizing Ctrl+Cmd+F
  — the menu shortcut every app carries — does not take effect, the same wall the Space hotkeys hit.
  It drives the focused window's `AXFullScreen` attribute through the Accessibility API instead,
  which is what third-party tools do and why binding a keystroke never could work.
- Focus-follows-cursor, APPS THAT FILL A DISPLAY ONLY (`settings.focusFollowsCursor`, off by
  default). Resting the cursor (~0.15s) on such an app makes it frontmost, so keystroke bindings
  land where you point. macOS has no public way to focus without raising, so the restriction is
  what makes it safe: an app already covering a display has nothing to disturb.
  Two measurements shaped the detection, both worth keeping:
  (a) a literal fullscreen test (window bounds == display bounds) matched NONE of the author's
      windows — Warp, Chrome and Music are all maximised, sitting 30–33pt below a visible menu bar;
  (b) `NSScreen.visibleFrame` is not usable as the target, because on a display that is not
      currently active macOS reports it equal to the full frame, reserving no menu bar, so an
      exact-cover test rejected exactly the windows it was meant to accept.
  So the test is a coverage FRACTION (>=90%) of the display, against the UNION of the app's windows
  on it — Chrome splits tab strip and content into separate CGWindows that only cover it together.
  Measured coverage: Warp 99%, Chrome 98%, Music 97%; a display with a Dock still clears ~93%.
  `FocusFollowsCursor` polls at 20 Hz — at a 0.15s dwell a 10 Hz poll left only one or two ticks
  inside the window, so the felt delay swung by a whole tick — but early-outs on a still cursor, so
  idling costs nothing.
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

- **App wheel** (`app/AppWheel.swift`): a radial launcher of `settings.appWheel`, summoned by an
  ordinary `{"action": "appWheel"}` hold binding — typically the layer key's. Being an ordinary hold
  binding is the point: it gets the progress card and the cancel grace with no code of its own. That
  required making layer keys first-class in the hold machinery (see below). It opens centred on the
  POINTER so choosing is a flick outward rather than a trip across the display, and selection
  follows the CURSOR rather than the finger's position, so the trackpad behaves as it always does.
  Select launches, any other button cancels, and a dead zone in the middle means summoning it and
  pressing Select does nothing by accident.
- **Window actions through the Accessibility API**, not keystrokes: `fullscreen`, `minimize`, and
  `closeWindow`. `closeWindow` presses the window's red button rather than sending Cmd+W, which in
  anything tabbed closes a TAB — and an app may bind Cmd+W however it likes, so pressing the real
  control is the only way to be sure which you get.
- TV button toggles `L1`.
- Siri button sends the right-side Ctrl+Cmd+Option chord; double Siri sends Enter.
- Global ring directions send arrow keys; double ring-left/right switch Spaces (`action: "space"`).
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
cd SiriRemoteCore
swift test

cd app
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

> ⚠️ **SUPERSEDED 2026-07-23 — the "closed on macOS" verdict was WRONG.** The *clean-API* half of this
> conclusion still holds (there is no CoreBluetooth path to the mic), but "no path at all on macOS"
> was too strong. A shipping, **ad-hoc-signed** Mac app was dissected and it reads the mic on macOS 26
> with only PUBLIC entitlements, by enabling HCI logging through a **debug-defaults mechanism we never
> tried** — which defeats the exact "Bluetooth Profile Required" wall that stopped our 2026-07-20
> PacketLogger run. Full method and the reproducible recipe are in **"Microphone — SOLVED on macOS
> (2026-07-23): how a real app actually does it"** at the end of this section. The Linux/ESP32 routes
> are no longer the *only* way to the mic.

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

### Microphone — SOLVED on macOS (2026-07-23): how a real app actually does it

> ✅ **REPRODUCED AND AUDIBLY VERIFIED IN OUR OWN CODE (2026-07-23).** Not just dissected — we ran the
> whole input pipeline ourselves and decoded the user's actual voice. One live capture on this Mac:
> holding Siri produced **804 Opus voice frames** on ATT handle `0x0035`; all 804 decoded cleanly
> (0 errors) through our `OpusVoiceDecoder` (libopus); the WAV played back and the user confirmed it is
> clearly their voice. Key facts learned: **no enable-write is needed** (the stream flows on Siri-hold
> with the remote merely paired to macOS — we only sniff), and the debug-defaults HCI switch
> (`HCISkipAuth`/`RawAudioTrace`) is confirmed to defeat the 2026-07-20 "Bluetooth Profile Required"
> wall. Full frame format and the reproducible pipeline are in `mic/README.md` (WIP, not yet
> integrated). This makes the mic a pure-macOS, ad-hoc-signed, no-ESP32 capability in practice, not
> just in theory.

### Codex continuation after Claude session `32a5bd05-6d33-4d42-b5b2-84697fb36bf8`

This is the complete handoff for the continuation performed on 2026-07-23. It deliberately includes
the failed system test and recovery, not only the successful code. The worktree remains uncommitted:
`.gitignore` and this file are modified; `mic/` is untracked. Do not lose it with a cleanup command.
`.gitignore` was extended for the generated driver/app bundles, C test binaries and router object/
executables so only source and documentation are candidates for a future commit.
`mic/build-test.sh` and `mic/router/build.sh` use task-specific Clang module caches under
`/private/tmp`; this avoids Swift trying to write the normally user-owned `~/.cache/clang` when tests
run in a restricted workspace.

#### Orientation and recovery of the previous session

- Read this handoff and recovered the previous Claude transcript from
  `~/.claude/projects/-Users-zhangwenqian-siriremote-release/32a5bd05-6d33-4d42-b5b2-84697fb36bf8.jsonl`.
- Located the still-existing real capture artifacts:
  - `~/.claude/jobs/32a5bd05/tmp/mic_spike/cap_mic.pklg`
  - `~/.claude/jobs/32a5bd05/tmp/mic_spike/mic_raw.txt`
  - `~/Desktop/siri_remote_voice.wav`
- Recovered the exact parser used for the audibly verified capture instead of reconstructing it from
  memory. The stable rule is: RECV packet, raw signature `04 00 1B 35 00`; ATT value is
  `[4-byte header][1-byte Opus length][Opus bytes]`; sequence is little-endian in value bytes 2–3;
  expected Opus TOC is `0xB8`; ACL connection handle is dynamic and must not be hard-coded.

#### Router implemented and revalidated

Added the following under `mic/router/`:

- `VoiceFrameParser.swift` — parses PacketLogger `nhdr` text and extracts only valid Siri Remote voice
  notifications.
- `SiriRemoteMicRouter.swift` — stdin/file router, Opus decode, WAV output, optional real-time replay,
  optional shared-ring output, statistics and expected-frame assertion.
- `SiriRemoteMicRingWriter.h/.c` and `router_shim.h` — user-process producer for the Float32
  POSIX-shared-memory ring.
- `test_parser.swift` and `build.sh` — deterministic parser test and standalone build.

Router behavior implemented:

- 48 kHz mono decode through `OpusVoiceDecoder`.
- Three-packet / 60 ms prebuffer before publishing the producer active flag.
- Duplicate suppression.
- Packet-loss concealment for small sequence gaps (up to 9 missing packets).
- Large-gap/new-hold discontinuity detection without synthesizing an enormous PLC gap.
- Ring producer lifecycle cleanup on normal exit and `SIGINT`/`SIGTERM`/`SIGHUP`.

Offline replay against the exact real capture was rerun after all later changes:

```text
parser test: PASS
router build: PASS
srm_router: lines=3071 voice=804 decoded=804 bad=0 duplicates=0 plc=0 discontinuities=2
srm_router: samples=771840 rms=3232.3 peak=32767 ring_write=0
```

This exactly matches the previous independently decoded result: all 804 frames decode, no codec
errors, 771,840 samples, RMS 3232.3. This run used `--no-ring`; it did not contact CoreAudio.

#### Virtual microphone work before the incident

The output experiment lives under `mic/driver/`. It is an AudioServerPlugIn fork of pristine
BlackHole (`vendor/BlackHole.c` plus its GPL-3.0 license; product changes are in
`SiriRemoteMic.c`/`SiriRemoteMic.config.h`). Added:

- 48 kHz, mono, input-only **Siri Remote Mic** device configuration.
- `SiriRemoteMicShared.h`: lock-free SPSC Float32 ring ABI at `/SiriRemoteMicAudio`.
- Read-only shared-memory attachment from the `_coreaudiod` process; the real-time ReadInput path
  uses atomics and copies only, with no allocation or blocking.
- `build.sh`, `install.sh`, `uninstall.sh`.
- `srm_test_writer.c`: bounded 440 Hz producer.
- `srm_capture_test.c` plus a microphone-authorized `.app` wrapper.
- `srm_usage_monitor.c`: observes CoreAudio consumer demand.

An earlier bounded system test did prove the IPC mechanism: an independent capture app read 144,384
non-zero samples, RMS 0.162295, peak 0.25, from a source with RMS 0.178589. That proves a user process
can feed a `_coreaudiod`-hosted plug-in through this POSIX ring. It does **not** mean the full HAL
implementation is safe; the later incident supersedes any previous “M2 complete” wording.

#### CoreAudio incident, diagnosis, and recovery

During a later installed-device/realtime-router test, the capture app hung during CoreAudio device
initialization. `coreaudiod` exceeded 100% CPU and other audio clients also spun; the Mac became nearly
unusable and the user rebooted it. This test caused the problem. It was not the built-in microphone.
Administrative authentication was supplied interactively for the system operation; no credential is
recorded in the repository or this handoff.

Evidence gathered before reboot:

- A `coreaudiod` sample showed the hot path in
  `HALC_ProxyNotifications::_SendPropertiesChanged` →
  `HALC_ShellPlugIn::ProxyObject_PropertiesChanged` →
  `HALC_ShellSimpleProxyList::Reconcile`.
- The Siri Remote Mic audio-I/O thread was mostly sleeping. The dominant failure was therefore an
  object/property notification and reconciliation storm, not PCM copying or Opus decoding.
- During diagnosis, the timestamp-anchor bug, duplicate OwnedObjects slot and published zero-stream
  mirror device were fixed, the bundle was rebuilt, and one additional installed attempt was made.
  The high CPU persisted. That attempt is important negative evidence: those three corrections alone
  were not sufficient. The later UID, no-Box, public-surface and property-contract fixes described
  below have **never** been installed.
- The plug-in was removed from `/Library/Audio/Plug-Ins/HAL/SiriRemoteMic.driver` before reboot and
  its absence was verified. Restarting audio after removal did not immediately drain the storm;
  rebooting did.
- After reboot the plug-in was still absent and the high-CPU audio storm was gone.
- A read-only check found
  `/Library/Preferences/Audio/com.apple.audio.SystemSettings.plist` still records preferred input
  order as `SiriRemoteMic_UID` index 0, `BuiltInMicrophoneDevice` index 1,
  `VirtualDesktopMic_UID` index 2. The plist was **not edited**. A pre-recovery copy was made at
  `/private/tmp/com.apple.audio.SystemSettings.before-srm-recovery.plist` before reboot, but a final
  read-only check found that temporary copy no longer exists after reboot; do not rely on it.

Current machine safety state:

- **UPDATE 2026-07-23 (post-fix): the FIXED bundle is now installed and VALIDATED on the real host.**
  Installed under an auto-rollback watchdog; both prior storm paths are clean — load reconciliation
  settled to idle in ~2 s, and the client-open IO path (the earlier trigger) peaked at only **6%**
  (was 100%+). A CoreAudio consumer received **147,456 non-silent samples** through the shared ring
  (`PASS`). The device did **not** become the default input (`kCanBeDefaultDevice=false` held; built-in
  mic stayed default), and `coreaudiod` idles at ~3%. The storm root cause (dynamic object graph +
  Box-driven DeviceList reconciliation) is confirmed FIXED, not merely avoided. Bundle currently
  **installed**; `mic/driver/uninstall.sh` removes it. The lines below describe the pre-fix state.
- `/Library/Audio/Plug-Ins/HAL/SiriRemoteMic.driver` was **not installed** (pre-fix state; now
  superseded — see the update above).
- No system audio preference was modified during recovery.
- The built-in microphone driver, format and default setting were never changed by this
  implementation. The planned fallback is not implemented. If fallback is eventually wanted, it
  only needs an ordinary, read-only AVAudioEngine capture while a consumer is using the virtual
  device; alternatively the safe behavior is silence whenever the remote is inactive.
- Do not reinstall merely because the local bundle builds. System validation is still blocked.

#### Confirmed HAL defects found and fixed offline

The following are concrete defects, not guesses:

1. **Input-only timestamp anchor was compiled out.** The first-client host-time initialization lived
   inside `#if kDevice_HasOutput`, so an input-only build could expose an invalid zero-time timeline.
   Anchor host time and timestamp counters now initialize independently of the output ring buffer.
2. **Plug-in OwnedObjects overwrote index 0.** The inherited two-object path wrote Box and Device to
   the same array slot. It now returns a correct list.
3. **A hidden second device with zero streams was published.** The mirror device was removed from the
   public device list and UID translation.
4. **Both UID translation size checks were backwards.** Correct
   `sizeof(CFStringRef)` qualifiers were rejected, while incorrect sizes passed. The bug was first
   encoded in a regression test, observed to fail in all four expected ways, then fixed for Box and
   Device translation.
5. **Resource-bundle output checked the wrong type size.** It checked `sizeof(AudioObjectID)` before
   writing a `CFStringRef`; it now checks `sizeof(CFStringRef)`.
6. **The inherited hardware Box made the device list dynamic.** Box acquisition can emit a plug-in
   DeviceList notification and trigger reconciliation. A software-only virtual microphone does not
   need a Box. The published graph is now static: PlugIn owns exactly Device; BoxList is empty;
   DeviceList always contains exactly the one primary Device; TranslateUIDToBox returns unknown.
   Box property dispatch is compiled out.
7. **Unpublished objects were still callable.** The Box, second device, output stream, output
   controls and pitch control are now rejected by the public dispatch path; I/O entry points also
   reject the unpublished second device.
8. **Capabilities did not match the physical shape.** The mono input-only device no longer claims
   default-output capability, no longer advertises a stereo channel pair, and reports a Mono channel
   label. It no longer advertises an icon resource that does not exist.
9. **Clock selector mutability was inconsistent.** AvailableItems and ItemName were advertised but
   `IsPropertySettable` returned UnknownProperty instead of read-only. They now consistently report
   read-only.
10. **Default-input eligibility is disabled during the unsafe/unverified phase.**
    `kCanBeDefaultDevice` and `kCanBeDefaultSystemDevice` are both false. Apps may explicitly open
    the device after a future safe install, but CoreAudio should not promote it to a system default.

These defects make the old bundle unsafe, but they do not prove that any one defect was the sole
trigger for the observed storm. The strongest causal hypothesis is an invalid/dynamic object graph
combined with failed UID reconciliation and Box-driven DeviceList notifications. Only a future
bounded system test can confirm that; no such test was run after the fixes.

#### New process-local HAL contract test

Added `mic/driver/srm_driver_contract_test.c` and wired it into `mic/driver/build.sh`. It `dlopen`s the
locally built bundle, calls `BlackHole_Create`, and supplies a fake `AudioServerPlugInHost`. It never
installs the bundle and never contacts or restarts `coreaudiod`.

Coverage now includes:

- Exact static object graph, owners, one input stream, no output stream, and no Box.
- Rejection of every inherited/unpublished object.
- Correct UID-to-device and UID-to-box behavior, including bad qualifier sizes and unknown UIDs.
- `HasProperty` / `IsPropertySettable` / `GetPropertyDataSize` / `GetPropertyData` for every published
  plug-in, device, stream and control property.
- Exact-size allocations surrounded by 32-byte canaries, catching size mismatches, underruns and
  overruns.
- Input-only/default/stereo/icon capability consistency.
- `WillDoIOOperation`, StartIO/StopIO, initial and advanced zero timestamps, and silence when no
  producer exists.
- 20,000 repeated reconciliation cycles of OwnedObjects, DeviceList, BoxList and UID translation.
  The graph remained fixed and the fake host received zero unexpected notifications.

Final results:

```text
normal optimized build: contract test: PASS
AddressSanitizer + UndefinedBehaviorSanitizer build: contract test: PASS
```

The normal build emits a local ad-hoc-signed bundle. That bundle exists only in the ignored
`mic/driver/SiriRemoteMic.driver/` build directory; it is not installed.

#### Installation safety gates added and verified

`mic/driver/install.sh` is now fail-closed:

1. It refuses unless the caller supplies the exact `SRM_SYSTEM_INSTALL_ACK` token printed by the
   script.
2. It refuses to overwrite an already-installed live HAL bundle.
3. It reads the preferred-input UID and refuses if `SiriRemoteMic_UID` is still index 0 unless a
   separate stale-preference risk token is supplied.

Both refusal paths were executed as tests. The second path currently triggers on this Mac. Neither
test reached `sudo`, copied a bundle, restarted `coreaudiod`, or changed an audio setting.
`build.sh` now ends by saying system installation remains fail-closed rather than suggesting the
user install immediately.

#### Real-time streaming SOLVED (2026-07-23, later) — fragment reassembly + jitter buffer

A clean, low-latency live ear-monitor now works end to end (user confirmed: real-time, clear, no
glitches; `voice=2659 decoded=2659 plc=0` over a 75 s window, monitor `underruns=15`). Three stacked
causes were found (the second was the real one, invisible until now, confirmed by dissecting
RemotePilot which ships an `A2854HCIReassembler`):

1. **PacketLogger `-s` (stdout stream) drops on backpressure** — a slow reader fills the 64 KB pipe and
   the tool discards HCI. Fix: never pipe. Capture with the lossless `-o FILE.pklg` mode (never
   backpressures) and TAIL the file. (RemotePilot does the same file-backed-tail shape.)
2. **THE REAL BUG: the router could not reassemble fragmented voice frames.** The ~99-byte voice ATT
   notification is split across **two ACL fragments** on the live wire. PacketLogger's *offline* text
   conversion reassembles them (why the captured FILE always decoded clean), but the live stream
   delivers fragments — the old parser required a whole frame and silently dropped first-fragments, so
   ~half the frames never decoded. This, not RF or the pipe, was the "loses half the frames." Fix: the
   router now does its own **L2CAP PB-flag reassembly** before parsing (`PklgTailReader.swift`).
3. **Monitor re-prime bug** — any underrun reset to a full 180 ms prebuffer, amplifying a dip into a
   180 ms silence gap. Fix: lock-free SPSC ring in C (`MonitorAudioRing.c`, render thread does one C
   call, no lock/alloc), prime 100 ms but **re-prime only one 20 ms frame** after an underrun.

Proof it is byte-exact: the binary `--pklg` path on `cap_mic.pklg` yields 804 frames, plc=0, and a WAV
with the **same SHA-256** as the proven-clean text path; a growing-file tail (records split mid-append)
stays 804/plc=0/identical. Latency floor is PacketLogger's `-o` flush cadence + the jitter buffer ≈
**100–250 ms** (sub-50 ms is impossible through any PacketLogger path). Run it:
`cd mic/router && ./live_monitor.sh [buffer_ms]` (needs the HCI trace enabled first).

**This also fixes the virtual mic's core audio quality** — the device is fed by the same router, which
was dropping the same fragmented frames.

#### Current boundary and remaining work

Safe and completed offline:

- Real PacketLogger capture → parser → Opus decode.
- Router sequencing/PLC/prebuffer and optional ring writer.
- HAL bundle build.
- Static HAL graph/property/I/O contract tests, 20,000-cycle reconciliation stress, ASan and UBSan.
- System plug-in removal and post-reboot read-only verification.

Not completed / not authorized:

- ~~**No post-fix system installation or CoreAudio test.**~~ **DONE 2026-07-23:** fixed bundle
  installed + validated on the real host under a watchdog (load + client-open + audio flow, no storm,
  did not hijack default input). See "Current machine safety state" above.
- **The device is validated but not yet USEFUL end to end:** no live router is running to feed it, so
  it currently emits silence. Next: wire `mic/router/` (live PacketLogger capture → voice-frame parse
  → Opus decode → ring writer) to the installed device, triggered when a consumer opens it + Siri is
  held. Then the built-in-mic fallback and jitter/clock-drift hardening.
- ~~No new live PacketLogger capture~~ / ~~No jitter/clock-drift correction~~ — **DONE 2026-07-23:**
  live capture + fragment reassembly + jitter-buffered monitor all validated live (see "Real-time
  streaming SOLVED" above). The live monitor path (`--monitor`) is clean; the DEVICE ring-feed path
  (router `--pklg` without `--no-ring` → HAL shm ring → consumer app) still needs its own live test —
  the HAL plug-in's ReadInput resync may need the same prime/re-prime treatment as `MonitorAudioRing`.
- **Still to do to finish the feature:** wire the router→device-ring feed with demand detection (run
  the capture+router only while a consumer holds the device open, via
  `kAudioDevicePropertyDeviceIsRunningSomewhere`); built-in-mic fallback; integrate into HyperVibe.

For any future system test, require a fresh explicit user decision. Prefer a disposable/test Mac. On
this daily machine, first resolve the stale preferred UID without hand-editing CoreAudio's plist,
keep default-device eligibility disabled, prepare a tested automatic rollback/watchdog, bound the
test duration, monitor `coreaudiod` from an independent terminal, and stop at the first sustained CPU
rise. Do not touch the built-in microphone configuration as part of installation.

See `mic/README.md` and `mic/driver/README.md` for the corrected component-level status.

A user-supplied, shipping macOS app — **`RemotePilot.app`** (`com.kyle.RemotePilot`, from a Chinese
creator "Kyle"; a sibling of the commercial **CouchVox** and the open-source
**`Jack-R1/SiriRemoteVoiceControl`**) — was **statically dissected** on 2026-07-23 (mounted, inspected,
never run — no system state changed). It reads the 3rd-gen remote's mic on macOS 26, and the dissection
hands us the complete, reproducible recipe. This retires the "closed on macOS" verdict above.

**Signing & entitlements prove it needs nothing special:**
- **Ad-hoc signed** (`flags=0x10002(adhoc,runtime)`, `TeamIdentifier=not set`) — no paid Apple
  Developer account, no provisioning profile.
- Entitlements are ALL public: `com.apple.security.device.bluetooth`,
  `com.apple.security.device.audio-input`, `com.apple.security.cs.disable-library-validation`,
  `com.apple.security.cs.allow-dyld-environment-variables`. **No private/restricted Bluetooth or DoAP
  entitlement.** So the method is fully reproducible by us.
- `LSMinimumSystemVersion = 14.0`; linked frameworks: CoreBluetooth, Speech, AVFAudio/AVFoundation,
  AudioToolbox/CoreAudio, MultitouchSupport (trackpad), SceneKit (the 3D remote model). Swift app.

**What it does NOT do (confirms our long-standing finding):** it does NOT reach the mic through a clean
CoreBluetooth GATT path. CoreBluetooth is used only for the buttons/HID (`SiriRemoteHIDButtonMapper`,
`SiriRemoteGATTInputEnable`, `SiriRemoteGATTReportReference`). The "OS protects the HID UUID service"
wall is real — the open-source `Jack-R1` project hit it too and said so verbatim. Nobody has a clean
API; the working path is **privileged HCI capture of your own paired remote**.

**The actual voice pipeline (extracted from the embedded shell scripts + Swift symbols):**

1. **Enable macOS HCI logging via debug DEFAULTS — not the `.mobileconfig` profile.** This is the step
   we were missing on 2026-07-20. The app writes, under an admin prompt
   (`osascript … "do shell script … with administrator privileges"`):
   ```sh
   PREF_DOMAIN=/Library/Preferences/com.apple.MobileBluetooth.debug
   defaults export "$PREF_DOMAIN" "$PREF_BACKUP"          # backs up first, restores on exit
   defaults write "$PREF_DOMAIN" HCITraces -dict \
       StackDebugEnabled -bool true  HCILiveTraces -bool true  HCIFileTraces -bool true \
       RawAudioTrace -bool true      HIDTrace -bool true       HCISkipAuth -bool true
   killall -30 bluetoothd                                 # reload so the debug prefs take effect
   ```
   - **`HCISkipAuth true`** is the flag that defeats the exact `bluetoothd: "Bluetooth Profile
     Required"` refusal that stopped our earlier PacketLogger attempt. We failed because we installed
     Apple's iOS-only `Bluetooth_macOS.mobileconfig`; the real switch is this debug-domain default.
   - **`RawAudioTrace true`** is what makes the voice frames appear in the trace; `HIDTrace` adds HID.
   - The domain is `com.apple.MobileBluetooth.debug` (writing `/Library/Preferences/…` needs admin;
     hence the osascript prompt). It exports a backup and restores it on teardown — clean, reversible.
2. **Capture the live stream** by shelling out to Apple's **PacketLogger CLI** (already on this Mac via
   Additional Tools 26.6): `/Applications/PacketLogger.app/Contents/Resources/packetlogger` (fallback
   `/Volumes/Additional Tools/Hardware/PacketLogger.app/…`), `--input/--output` to a `capture.txt`,
   then `packetlogger convert -s -f nhdr` to parse; it tracks and `kill -INT`s the capture PID on stop.
3. **Reassemble** HCI PDUs (`A2854HCIReassembler`) into voice reports (log format: `voice stream
   started report=0x… voiceInterface=… sequence=… opusBytes=… toc=0x…`). `A2854` = the gen-3 remote's
   model number, so this is our exact device.
4. **Decode Opus** (`A2854OpusDecoder`) → `AVAudioPCMBuffer` (the WB CELT/48 kHz mono frames the Linux
   impl also described).
5. **Speech + inject**: `SFSpeechRecognizer` / `recognitionTaskWithRequest:` → text → typed into the
   frontmost app via `CGEvent`. Push-to-talk = hold the Siri button.

**Reconciliation with our own record.** Our 2026-07-20 run *did* reach `BTLEServer` and got ATT error
130; that, plus the profile rejection, is fully consistent — we simply never flipped the
`com.apple.MobileBluetooth.debug → HCITraces{…HCISkipAuth,RawAudioTrace}` switch that unlocks live HCI
tracing without the (unavailable) profile. The 2022 `BTLEServerAgent`/DoAP entitlement CVE is the same
subsystem; the debug-defaults path is the sanctioned-for-debugging way in.

**What this changes:**
- The microphone is **achievable on pure macOS 26**, ad-hoc signed, no paid account, no ESP32/Linux.
  This **decouples the mic from the hardware roadmap** — the board is no longer the *only* path to it.
- To just HAVE the feature: run RemotePilot (or CouchVox). To OWN it: reproduce the 5-step pipeline
  above in our own app — every piece is now known, and none needs a private entitlement.

**Honest caveats (why it's a hack, not a blessed API):**
- Needs the **admin password** (writes a system `/Library/Preferences` debug domain).
- Depends on Apple's **PacketLogger** binary being installed (Additional Tools) and on **undocumented
  debug prefs** (`HCITraces`, `HCISkipAuth`, `RawAudioTrace`) that Apple can change or remove in any
  OS update. It is debug instrumentation, not a supported interface.
- `killall bluetoothd` briefly drops every Bluetooth device on the Mac while it reloads.
- It is privileged HCI sniffing of your OWN paired remote on your OWN machine — fine for personal use;
  not something to ship to others without thinking about what enabling system HCI tracing exposes.
- The ESP32 route remains the only path that needs no admin, no PacketLogger, and no debug prefs (the
  board is the GATT client and reads the voice characteristic directly) — so it is still the clean,
  own-it-end-to-end option, just no longer the *mandatory* one for the mic.

## Settled — Space switching, and why BetterTouchTool was never actually needed

**Resolved 2026-07-21. No part of the project depends on BetterTouchTool any more.**

The `space` action had been silently broken for its whole life, and that is what made BTT look
necessary. Three routes were measured, judged by PIXELS — the reported space index is not evidence,
because the private call moves the index without moving the screen:

| route | result |
|---|---|
| CGEvent synthesis of Ctrl+Arrow | **no-op.** WindowServer reads the real *hardware* modifier state. Pressing Ctrl+Arrow physically does switch, which is how we know the shortcut itself is enabled. |
| private CGS/SkyLight (`CGSManagedDisplaySetCurrentSpace`, and with `CGSShowSpaces`/`CGSHideSpaces`) | **moves the bookkeeping, not the screen.** 568 of 20,358,144 pixels differed across the call. Worse, it leaves record and display disagreeing, which then corrupts anything measured afterwards. |
| **System Events `key code … using control down`** | **works, with the native animation.** AppleScript's Accessibility injection is not subject to the hardware-modifier check. |

`Spaces.switchSpace` now uses System Events. It needs Automation permission (macOS prompts once);
without it the call fails silently, so the failure is logged.

Three dependencies removed:

- `ring.left/right.double` — was `open -g "btt://trigger_action/?…113/114"`, now `action: "space"`.
- **Spaces Mode** — the only *hardcoded* BTT use, two shell commands in `RemoteInputHandler`, now
  `Spaces.switchSpace(±1)`.
- `button.playPause.double` — was `ctrl+F` for BTT to catch, now the native **`ctrl+cmd+F`**
  ("Enter Full Screen" in every app's View menu). App-level menu shortcuts do respond to ordinary
  synthesized events; it is specifically the Space/Mission Control system hotkeys that do not.

Mission Control never needed BTT: `open -a 'Mission Control'` is native and already in use.

Method note: the first two attempts at this concluded the opposite, because they measured the space
INDEX rather than the screen, and because mixing the fake CGS call into a test run desynchronises
the record from the display and poisons every later reading. Measure pixels, and never mix routes
in one run.

## Layer resolution — two rules that are not obvious

Both were added after the obvious version misbehaved, and both live in `Controller.site(_:)`.

**A layer key is a normal participant in the hold machinery.** A `.layer` binding used to consume
its own press and `return` before stage timers were ever armed, so a layer key could not carry hold
bindings at all — which is why the app wheel's first cut had a bespoke timer and no progress card.
Now a layer key with hold stages falls through to the normal path: tap still toggles, holding it
WITH another key is still momentary, and holding it alone reaches its hold binding. Reaching a stage
unwinds the layer that was engaged optimistically on press.

**A layer claims a button WHOLE, not one variant at a time.** A button's variants live under
separate keys — `button.playPause`, `.hold`, `.hold2`, `.double` — so a per-key fallback let the
unlayered ones leak in underneath a layer that had plainly taken the button over: binding
`L1.button.playPause` to Copy and its `.hold` to Cut still left the base `.hold2` opening Music at
1.0s. Now, if a layer binds ANY variant, its silence about the others is read as deliberate. A
button the layer binds no variant of still falls through entirely — that is what keeps a held layer
from deadening keys it has nothing to say about.

## The bug class this codebase keeps producing — state that outlives its trigger

Found the same shape five times in one day, then audited for it deliberately. Worth stating plainly,
because it will happen again the next time a feature adds press-scoped state.

**The shape:** something is started by an event (a press, a touch, a dim) and ended by its
counterpart (the release, the lift, the next activity). Then a path appears that skips the
counterpart, and the thing runs forever.

**The three paths that skip it here**, all real:

1. **The Power input guard** (`RemoteInputHandler`, "inside the input guard … return") returns for
   press AND release. Everything scoped to a press leaks when a release lands inside that ~1s.
2. **Device disconnect** ends a press with no release at all. BLE remotes disconnect on idle, so
   this is routine, not exotic.
3. **Process death.** Clean quit runs `cleanup()`; a crash runs nothing.

**What it produced.** Ranked by how far the damage escapes the app:

| leak | escaped to | how it was fixed |
|---|---|---|
| sticky drag not ended on disconnect/quit | left mouse button held down **system-wide** | ended in `releaseAllHeldKeys` + `cleanup` |
| `dragStartWork` firing after a swallowed release | posts `mouseDown` with nothing held — same result, with no remote attached | cancelled in `endPressScopedWork` |
| auto-repeat surviving its press | typed forever; only unpairing stopped it | ground-truth check per tick against `buttonState` |
| brightness dim on quit | every display left at minimum, after the process is gone | `Brightness.restoreIfDimmed()` in `cleanup` |
| `com.apple.rcd` boot-out after a crash | rcd gone for the **whole login session**; later clean quits no-op'd because `suspended` was false | next launch ADOPTS an already-booted-out rcd |
| momentary layer on a swallowed release | every key resolved inside the layer, no indication, until the layer button was cycled | unwound in `endPressScopedWork` |
| stale hold-stage timers | a later quick TAP dispatched the long-press action | cancel before overwriting `holdStageTimers` |
| hold HUD never told the hold ended | card pinned over every Space with a 60 Hz repaint | `onHoldEnded?(0)` from `endPressScopedWork` |
| `.repeatKey` replaying keys captured at press time | a repeating Delete kept deleting in whatever took focus | re-resolve the binding every tick |

**The rules that came out of it:**

- Everything a press arms must be cancellable from ONE place. `endPressScopedWork` is that place —
  add to it, never alongside it. Both times this was patched per-symptom instead, the next path to
  skip a release leaked whatever had been added since.
- A guard that suppresses an ACTION must not also suppress the BOOKKEEPING. Suppress the effect,
  still end the press.
- A repeating timer should verify ground truth each tick rather than trusting the state that armed
  it, and re-resolve what it dispatches rather than replaying a capture.
- Anything changed OUTSIDE the process (mouse button, brightness, a booted-out daemon) needs an
  answer for a crash, not only for a clean quit — at minimum, adopt the orphaned state on next
  launch, the way rcd now does.

## Future direction — move the whole engine onto an ESP32-S3 (design record, nothing built)

Recorded 2026-07-21 from a design discussion; extended 2026-07-22. Nothing here is implemented, but
**hardware has shipped**: 2× M5Stack AtomS3R (K147) from DigiKey AU, ordered 2026-07-22, **shipped and
due Tuesday 2026-07-28** (see Hardware notes for why AtomS3R and why two). It is written down because
the conclusions were reasoned out once and would otherwise be lost.

> **When the boards arrive and firmware work begins, code quality is not optional — it is the
> priority.** This is a long-lived controller that runs unattended; sloppy firmware fails silently in
> the field where there is no debugger attached and no console to read. Before writing a line of
> ESP-IDF: re-read "The bug class this codebase keeps producing — state that outlives its trigger"
> below, because the firmware's HUD state machine and the BLE/USB dual role are exactly where that
> class reappears. Hold the same bar the Swift code holds — one source of truth per piece of state,
> no independent code paths mutating the same thing, every resource (BLE handle, DMA buffer, held HID
> key) released on exactly one path. Do not treat "it's just embedded/a prototype" as licence to cut
> corners; the opposite is true.

### The architecture

```
Siri Remote --BLE--> ESP32-S3 (all processing) --USB HID--> any host
```

The board owns the remote as a BLE central, runs the mapping engine itself, and presents to the
computer as an ordinary USB keyboard/mouse. The host installs nothing.

Why this is probably better than the current Mac-side app:

- **Lower latency, not higher.** Today: `BLE -> macOS BT stack -> MultitouchSupport -> our app ->
  CGEvent post -> system`, with a full userspace round trip in the middle. Proposed:
  `BLE -> ESP32 -> USB HID (~1 ms)`, skipping that hop entirely. The 15 ms BLE connection interval
  is unchanged and dominates either way — it is a floor set by Apple's accessory guidelines.
- **Windows works for free.** The blocker identified for a Windows port was that there is no clean
  userspace way to *seize* a HID device, so native behaviour would double-fire. If the host only
  ever sees an ordinary mouse, there is nothing to seize.
- **Distribution stops being a problem.** No Accessibility permission, no private frameworks, no
  Developer ID signing or notarisation, so no paid Apple account. (True at Tier 0 — board alone. A
  helper for the on-screen HUD reintroduces some unsigned-app friction; see the tiers below.)
- **The HUDs move to the board's own screen**, where they do not cover the user's work. (Tier 0; with
  a helper they can instead draw on the host screen — see below. The choice is per-platform.)

### What is lost, and the mitigation

- **Per-app modes.** The board cannot know which app is frontmost. Mitigation: a very small Mac
  helper that sends the frontmost bundle ID over USB serial and does nothing else — reading the
  frontmost app needs no special permission, so that helper stays unprivileged and unnotarised.
  Heavy input path stays pure HID; only context comes over serial.
- **Non-HID actions.** Some can be done with pure keystrokes and need nothing on the host; a few
  genuinely cannot and need a helper. This split was too glibly stated before — it is spelled out
  precisely in "Which actions need a host helper" below.
- **`SiriRemoteCore` must be rewritten in C.** The logic ports directly; the code does not. The
  render layer (wheel/HUDs) also ports to each host's helper, not the board — see below.
- The remote pairs to ONE host, so this is all-or-nothing — the touchpad moves with it.

### Host software is tiered; each tier costs more and reaches fewer platforms

The board alone is already the product. With NOTHING on the host it is a full keyboard/mouse/media
device: the entire mapping engine, gestures, layers, multi-tap and holds all run on the board, and
the HUD draws on the board's own screen. That is Tier 0, it works on any host plugged in with zero
install, and the floor is already high. Everything a host helper adds is enhancement on top of it.

- **Tier 0 — board only.** Full input on any host, no install; HUD on the board's 0.85" screen. This
  is the entire capability on iPad (below), and the baseline everywhere.
- **Tier 1 — a small on-board helper.** Carried on the board's own flash, run on the host. Draws the
  wheel/HUD as an on-screen overlay and executes the host-only actions. One platform fits in the free
  flash (sizes below).
- **Tier 2 — full helper from the cloud.** Config UI, auto-update, extra platforms — anything too big
  for flash, downloaded when wanted. The cloud does NOT escape code-signing: an unsigned build trips
  Gatekeeper on first run whether it came off the board or the internet — the no-paid-account problem
  is unchanged by where the bits come from, and a downloaded file carries the quarantine flag, so it
  is if anything stricter.

Per platform the ceiling differs, and it is not negotiable:

- **Mac / Windows** — all three tiers; full experience with a helper.
- **Linux** — Tier 0 native (HID is accepted with no seize needed). Helper doable on X11, curtailed
  on Wayland (arbitrary always-on-top overlays are restricted, same spirit as iPad); auto-mounted
  drives are often `noexec`, so "double-click to run off the board" is not smooth. DE-specific.
- **iPad — Tier 0 forever.** iPadOS runs no external executable: not off the board's virtual drive,
  not from the cloud. Input + board-screen HUD, permanently, nothing more. This is the one hard wall,
  and it is *the reason the board exists* — the Mac app cannot run on an iPad, so the board is the
  only way the remote reaches one.

### Which actions need a host helper, and which are pure HID

The precise test is: **can you do this by hand with only the keyboard?** Yes → the board does it as
pure HID, nothing on the host. No → it needs the helper.

- **Pure HID, no helper** — every keystroke and mouse action; media/volume/brightness (HID Consumer
  Control page); **opening an app** (the board types into Spotlight / the Start menu: `Cmd-Space`,
  name, Return — this is why "open Music" and the app wheel's *launch* work with nothing installed);
  opening a URL; switching tabs; copy/paste; arrow-key desktop browsing.
- **Needs the helper** — exactly the four actions already proven un-synthesisable: **Spaces
  switching**, **fullscreen**, **close-window** (the red button via Accessibility — `Cmd-W` closes a
  tab instead), **graceful quit of a named app** (`Cmd-Q` is not equivalent). These sit above the HID
  abstraction layer; no USB device class can express them. On Mac the helper runs them as AppleScript
  (osascript) needing Automation permission — a per-app prompt, milder than Accessibility / Input
  Monitoring, but not nothing.

So the app wheel splits cleanly: its **function** (push a direction, launch the app) is pure HID and
needs no host software; only its **on-screen visual** (the liquid-glass ring) needs a helper —
without one the ring draws on the board's screen and the launch still fires.

Design consequence: **prefer keystrokes over AppleScript wherever both work.** AppleScript is
macOS-only and pins a feature to the Mac; a keystroke is portable across every tier and host. The
current config is AppleScript-heavy only because it grew inside a Mac-only app; a board-first config
should reach for AppleScript only for those four actions that genuinely require it.

### The host helper is a stripped subset of the current app (measured 2026-07-22)

The full app today is **4.2 MB bare / 5.4 MB bundled, arm64 single-arch**. That includes everything
the helper does NOT need: HID seize, MultitouchSupport, the whole settings UI (SettingsView, the
834-line drawn-remote LayoutView, TuneSettings), and the config engine.

The helper keeps only the render + action files, which are already written: `AppWheel.swift` (374),
`HoldProgressHUD.swift` (446), `DragIndicator.swift` (119), `LayerHUD.swift` (227),
`MacActionExecutor.swift` (187) — ~1,350 lines — plus a serial reader (tens of lines) that receives
commands from the board over CDC and dispatches them. So the helper is not written from scratch: lift
these files, add a serial loop, delete the rest. Estimate **2–3 MB, arm64**. It stays small because
SwiftUI/AppKit and the Swift runtime ship with macOS (dynamically linked, not bundled) and every
visual is vector `Path`/`Canvas` drawing with no bitmap assets. Keep it single-arch (Universal
doubles it), no heavy framework, no image assets.

**Windows helper** is a separate binary — the render code does not port (Swift/SwiftUI → C++/Direct2D
is a rewrite of the drawing calls, though the geometry and easing are the same maths). Native **Win32
+ Direct2D draws the wheel and every HUD** (arcs, rounded rects, translucency, anti-aliasing all
native) as a layered click-through window (`WS_EX_LAYERED | WS_EX_TRANSPARENT`), and comes in **under
1 MB** — smaller than Mac, because Win32 is OS-provided too. The trap is the framework: .NET is
several MB, Qt 15–30 MB, Electron 80–150 MB. For this, native only.

### Storage and the self-carried installer

The board can be a **composite USB device — HID + CDC serial + mass storage** — so its own flash
appears as a small drive holding the helper. Plug in → a disk appears → drag the app / run the .exe.
No download, no internet; the helper travels with the hardware.

- **No auto-run, anywhere.** Modern macOS/Windows never auto-execute from a plugged-in device — this
  is exactly the malware vector they all closed. The "keyboard types the install commands" trick
  (Rubber Ducky) exists but is an attack technique: fragile, Gatekeeper-blocked, corrosive to trust.
  Do not build it. The honest best is "installer rides on the board, one manual launch, automatic
  thereafter," not "plug in and it installs itself."
- **Storage math.** 8 MB flash is shared with the firmware (NimBLE + TinyUSB + engine, ~2 MB), so
  ~5–6 MB is free for the drive. One platform's helper fits comfortably (Mac 2–3 MB, native Windows
  <1 MB). Two native helpers together (~3–4 MB) are tight but may fit. Beyond that, or any framework
  build, use the cloud tier — or an external **microSD** (the Atomic TF-Card reader on the exposed
  GPIO/SPI: `cs=5 mosi=6 sck=7 miso=8` on AtomS3), which makes storage gigabytes. For the current
  plan (config + bond info + one helper) the 8 MB internal flash is enough; a card is worth it only
  if you want every platform's helper carried on-board.

### Auto-connect and multi-board registration

Scan → filter → connect → reconnect-on-drop is standard NimBLE and the board can do it. What matters:

- **Bonding is still the gate.** None of it begins until the board completes Apple's encrypted bond —
  the same first-milestone unknown. Scanning and reconnecting are trivial; the security negotiation
  is the whole risk.
- **The remote sleeps.** A BLE peripheral does not advertise continuously; the remote likely wakes
  and advertises for a few seconds only when a button is pressed. "Leave it in a drawer and it
  connects itself" is unlikely — expect "press a key to wake it, board connects within a second or
  two." Physics, not a bug.
- **It may already be claimed.** A remote bonded to an Apple TV/Mac may not offer itself; it may need
  un-pairing there, or pairing mode (hold Back + Volume-down).
- **Multi-board → register once, then automatic.** With two boards (two devices, per the purchase),
  "connect to any Apple remote you see" makes the boards FIGHT over one remote and risks grabbing a
  stranger's. Right design: a one-time pairing mode per board that stores the chosen remote's address
  in flash; thereafter each board auto-connects only to its own remote. A new remote is a one-time
  registration, automatic forever after.

### What the AtomS3R board itself brings

- **9-axis IMU on board** (BMI270 accel+gyro + BMM150 magnetometer): it senses the BOARD's attitude —
  **tilt (pitch/roll) is reliable** (accelerometer has gravity as an absolute reference), **heading
  (yaw) is flaky** (magnetometer, disturbed by metal/electronics). The **remote has no IMU** on this
  generation, so there are no "wave the remote" motion gestures — only the board can be moved.
  Auto-rotating the board's own screen is a clean first project (accelerometer only; lock when laid
  flat, add hysteresis or it flickers at the boundary).
- **OS fingerprinting.** As a HID device the board cannot be TOLD what the host is, but can infer the
  family from host behaviour: Windows asks for a Microsoft OS Descriptor (nobody else does → strong
  signal); Apple's USB stack behaves distinctly from Linux. Enough to auto-load the right modifier set
  (Cmd- vs Ctrl-shortcuts) on plug-in. It **cannot** tell Mac from iPad from iPhone (same USB stack)
  and **cannot** read the frontmost app over USB (that still needs the serial helper, Mac-only).

### The honest bottom line on whether the board is worth building

The host action ceiling is identical to any keyboard/mouse — the board unlocks nothing a keyboard
couldn't reach, and the four helper-only actions stay helper-only. The board's value is not a higher
ceiling; it is that **the 3rd-gen remote cannot be a usable keyboard/mouse by itself** (it exposes
only Consumer + Digitizer, and its trackpad needs MultitouchSupport on macOS — pair it straight to a
computer and you get no cursor). The board is the brain/translator that turns that unusable device
into a fully configurable, host-native keyboard/mouse — portably.

So: **on Mac only, and willing to install, the current app is MORE capable** (it already has the four
AppleScript actions and the on-screen HUD, no extra hardware). The board is a sidegrade there, a
downgrade unless you add the helper. Its unique, non-substitutable payoff is **iPad** (and secondarily
Windows, no-install, lower latency). Build the board if controlling an iPad is the goal; if the goal
is only a better Mac experience, invest in the app instead.

### Tier 0 on-board HUD — a display language designed for 128×128, auto-switched

The board's 0.85" / 128×128 screen is where the HUD lives whenever there is no host helper (iPad
always; Mac/Windows before the helper runs). It is NOT a shrunk copy of the Mac overlay and must not
be built as one — the Mac wheel earns its look from translucency over the work behind it, whereas the
board's screen has nothing behind it. This is a HUD language redrawn from scratch for a tiny opaque
panel, and the panel **auto-switches** along two independent axes.

**Axis 1 — vertical: a priority state machine.** The screen shows exactly ONE thing at a time (128px
cannot tile). When several states want the screen, the most time-critical wins; when it clears, the
screen falls back to the next. Highest to lowest:

1. **Hold progress** — you are pressing; you must see which stage you are at, live.
2. **App wheel** — you are picking an app.
3. **Layer toast** — a layer just changed; shown briefly (~1–2 s) then it rejoins idle.
4. **Sticky-drag badge** — something is held; persistent until dropped.
5. **Idle default.**

A higher state pre-empts the instant it appears and the screen auto-returns on its exit — start a
hold while "L1" is showing and it becomes the progress ring; release and it drops back. No manual
action; the screen tracks what your hands are doing.

**Axis 2 — horizontal: idle content depends on whether a host helper is present.** The board learns
this from the CDC serial link: the helper sends a periodic heartbeat; heartbeat seen → the host
screen is covering feedback, so idle can show remote battery / link quality or dim to save power; no
heartbeat (iPad, or Mac with nothing installed) → the board screen is the ONLY feedback, so idle
shows the current layer (BASE / L1) and a connection dot. Detection is automatic on plug-in, no
setting.

**Per-state drawing for 128×128 (this is the spec, not the Mac one):**

| State | Draw | Note |
|-------|------|------|
| Hold progress | thick ring filling around the rim + stage name centred | cancel stage greys out; the screen's strongest use — it *is* a progress gauge |
| App wheel | four directional icons (~40 px) + the selected one enlarged + its name along the bottom | **no wedge, no glass, no translucency** — a lit icon, not a ring overlay |
| Layer toast | one big glyph (L1) filling most of the panel | flashes on switch, then folds into idle |
| Sticky drag | a hand glyph + "held" | persistent until dropped |
| Idle · no helper | current layer + connection dot | the sole feedback source, so it must carry real state |
| Idle · helper present | battery / link, or dimmed | the host screen has taken over; this defers |

**Three rules that separate it from the Mac HUD, and must hold:**

1. **Information, not an overlay.** The background is black; chase high contrast, not translucent glass.
2. **Solid fills, big icons, thick strokes.** Anything fine turns to mush at 128 px; be bold to be legible.
3. **One thing at a time.** Only ever the current highest-priority state — never a dashboard.

**Implementation notes:**

- **Redraw only what changed** (the progress ring's rim each frame, not the whole panel) or it flickers.
- **Double-buffer** — compose in a back buffer, push once. This is one of the few places the AtomS3R's
  8 MB PSRAM genuinely earns its place; the Lite (no PSRAM) would struggle here.
- **Single source of truth**: one `currentHUDState`; every transition writes it, the renderer reads
  only it. Do NOT let several code paths each draw independently — that is precisely the state-leak
  bug class the main app kept producing (see "The bug class this codebase keeps producing"); do not
  reproduce it in firmware.

### HUD icons on the board

Two kinds, sourced and stored differently:

- **Action icons** (play, pause, cancel, close-window, copy, paste, mute, volume…) come from **SF
  Symbols exported as 1-bit bitmap arrays**. The pipeline, so it doesn't have to be re-derived: pick
  the symbol in the SF Symbols app → export SVG → rasterise to a small target (32×32 or 40×40),
  white-on-transparent (the panel is black) → convert to a C array with **image2cpp** (web, "vertical
  bytes, 1-bit") or an Adafruit-GFX bitmap script → draw with LovyanGFX's
  `M5.Lcd.drawBitmap(x, y, w, h, icon, TFT_WHITE)`. Collect them in a table keyed by action so the
  HUD state machine can fetch one: `const uint8_t* iconFor(ActionKind)` → `switch` returning the
  array; this plugs straight into the `currentHUDState` renderer above. A 32×32 1-bit icon is 128
  bytes; ~20 of them ~2–3 KB — negligible in 8 MB.
- **Real app icons** (WeChat green, Chrome, Music) can't be drawn or symbol-fonted — store them as
  small colour bitmaps (RGB565, ~3 KB at 40×40). Still KB-scale; the storage headroom is unaffected.

The Mac helper does NOT use any of this — it calls SF Symbols through the system API and reads real
app icons from macOS directly. So the two screens align visually (play is a triangle on both) but
draw from different sources: system on Mac, exported bitmaps on the board.

Licensing note, since the repo is public: **this is fine for personal use, but do not commit the
exported SF Symbols assets into the public repo** — that would be redistribution of Apple's artwork,
which the SF Symbols licence forbids (using them on Apple platforms via the API, as the Mac helper
does, is fine; embedding them in non-Apple firmware and shipping them is not). Keep the exported
bitmaps out of Git (`.gitignore`) and generate them locally at build time. Using them privately on
your own board is not the concern; publishing them in the repo is.

### Hardware notes

**Bought (2026-07-22; shipped, due Tuesday 2026-07-28): 2× M5Stack AtomS3R, the K147 "AI Chatbot"
kit, AU$31.75 each, DigiKey AU, free UPS/DHL 3-day.** Reasoning behind the choice:

- **AtomS3R** = ESP32-S3-PICO-1-N8R8 (dual-core 240 MHz, 8 MB flash + 8 MB PSRAM), 0.85" 128×128 IPS
  screen, 9-axis IMU, IR TX, and — the make-or-break — **native USB-OTG** (USB-C wired to the S3's
  own USB pins, verified: same SiP as the AtomS3 that people have demonstrated as a USB-HID
  keyboard/mouse). 24×24×12.9 mm. **No battery, no battery connector** (T001 TailBat is listed
  compatible if wanted).
- **Two** because there are two target devices (two remotes likely), and because a pair doubles as a
  test rig: flash one as a fake BLE-HID mouse and have the other connect to it, proving the
  central+peripheral dual-role logic without depending on whether the remote will cooperate.
- **The kit bundles an Atomic Voice Base (ES8311 mic + speaker) that this project does not need.** It
  came only because the bare AtomS3R (C126, AU$25.84, would have saved ~AU$6 and the dead weight) was
  **out of stock**. The voice base's *speaker* is, however, genuinely useful in the pure-plugin case:
  a HID device cannot reach the host's speaker any more than its screen, so on-board audio is the only
  way to give audible feedback (layer change, connect/disconnect, hold-cancel) — it backfills the HUD
  that iPad can't show. Its *mic* has no use here (the remote's own mic is a separate, GATT-locked
  problem the base does not touch).

Boards considered and rejected:

- **M5Stack StickS3 (K150)** is the better board — 1.14" screen, **built-in 250 mAh battery** (enables
  wireless BLE-HID-to-host on battery, and a roomier screen for the wheel), same S3-PICO, native USB.
  Rejected only because it was **backordered to ~2026-09-08**; mixing it into an in-stock cart risked
  holding up or split-shipping the whole order. Revisit if a battery/wireless form factor is wanted.
- **Waveshare ESP32-S3-Touch-LCD-1.28** (the tempting round-screen board) is **disqualified**: its
  USB-C goes through a **CH343P UART bridge** (to GPIO43/44), not native USB, so it cannot do USB HID.
  This is the make-or-break trap — always confirm native USB, never a CH340/CP2102/CH343 bridge.
- **Waveshare ESP32-S3-Touch-AMOLED-1.75** passes the native-USB test (USB-C to the S3 pins) and adds
  a 466×466 AMOLED, dual mics, and a battery header — the right pick if a large round HUD matters —
  but is much larger and breaks out only **3 GPIOs**. Overkill for a first build.
- **M5Stack Tab5** was rejected earlier: its ESP32-P4 has no radio; BLE comes from a separate C6 over
  a hosted bridge whose GATT-handle addressing (the entire crux) is unverified. A single S3 has BLE 5
  on-die and no bridge.

**AtomS3 Lite (C124, AU$12.99, native USB confirmed via its CircuitPython port) is the cheap fallback
board** — same S3 CPU, so identical for pure bridge/gesture work (that workload is trivially light;
both boards idle >99% of the time), but **no PSRAM, no screen, no IMU**. Fine as an invisible bridge
or a test target; can't show any on-board HUD. Not bought this round, but noted as the minimum viable
board if another is ever needed.

### What the microphone needs (already known, not guessed)

The mic is not an unknown protocol; it is a solved problem on a permissive host. From
`azais-corentin/siri-remote`, which targets this exact generation:

- enable byte `0xAF` written to the writable Feature Report characteristics;
- audio arrives as wire report `0xFA`, 99-byte Opus payload;
- Opus CELT-only WB, TOC `0xB8`, 48 kHz mono, 20 ms / 960 samples per frame;
- it streams only while the Siri button is held.

macOS fails for one specific reason: the remote exposes **eight Report characteristics sharing one
UUID**, and the enable byte must reach a particular one, addressable only by GATT handle. BlueZ can
do this once its `hog` plugin is disabled; macOS splits those eight into separate IOHID interfaces,
rewrites the report IDs, and offers no way to name a handle — so its ATT write lands on the wrong
characteristic (`bluetoothd`: `Error setting feature report for ID #241 ... Code=130`). On an ESP32
the firmware *is* the GATT client, so every handle is directly addressable.

**Biggest unknown for the ESP32 route: bonding.** HOGP mandates an encrypted link before the HID
service is accessible, and Apple peripherals are fussy about security negotiation. First milestone
should be nothing more than: connect, bond, and dump the full GATT database with handles. That one
output converts every remaining assumption into fact.

### Researched and set up since (2026-07-22/23) — not built, but the ground is prepared

- **Bonding confidence is up, from evidence, though still unproven end-to-end.** ESP32+NimBLE as a
  BLE-HID CENTRAL is a solved, shipped pattern (`esp32beans/BLE_HID_Client` connects to a Microsoft
  Bluetooth mouse, a BLE trackball, gamepads) — but that project does not exercise bonding, which is
  our actual risk. The narrowing fact: Apple HID peripherals use STANDARD HOGP requiring LE Secure
  Connections + authenticated pairing, and NimBLE implements exactly that (`passkey_mode:
  secure_connections`; projects targeting iOS/macOS hosts rely on it). So the earlier fear "NimBLE
  might lack a feature Apple demands" is largely retired — the required feature is present. What is
  still unverified is only the specific remote+NimBLE pairing handshake in practice, which is
  precisely what the first milestone tests. Net: cautiously optimistic, no known blocker, plus the
  Linux/BlueZ precedent proving the remote will bond to a non-Apple central at all.
- **macOS provably cannot answer the bonding question — measured live.** Querying the connected
  remote: `system_profiler` shows it as BLE, Apple `0x004C`, product `0x0315`, firmware `0x0021`,
  address `E0:C3:EA:A3:03:4D`; `ioreg` exposes **8862 parsed HID elements** (the digested report
  structure) but **zero raw GATT handles / characteristics** (`grep -c GATTCharacteristic|ATTHandle`
  = 0). macOS hands up the chewed HID and hides the GATT+SMP layer entirely — the same wall as the
  mic. So no amount of Mac-side probing predicts ESP32 bondability; only a stack that operates at the
  raw layer (ESP32 or Linux) can, by trying. This is the concrete reason the board is the only path.
- **BLE-forwarding latency budget** (if the board talks to the host over BLE instead of USB): two
  BLE hops. Remote→board ~7.5ms avg (15ms interval, Apple-fixed floor, exists in every scenario);
  board→host BLE ~4–7.5ms avg. **End-to-end ~12–20ms**, ~on par with a wireless Magic Trackpad and
  comfortably inside "tracks the hand" for indirect pointing (which tolerates ~40–50ms of input
  latency; the display pipeline adds 30–60ms regardless). USB forwarding is ~5–10ms less (second hop
  → ~1ms). Two honest unknowns: BLE has more jitter than USB (2.4GHz interference), and the ESP32
  running BLE central+peripheral on ONE radio time-shares — that dual-role concurrency is the real
  thing to measure. The smoothness FLOOR isn't our hop anyway: the remote reports touch at ~60Hz
  (measured 63Hz), fixed in hardware. So wired-vs-wireless latency is dwarfed by the remote's own
  60Hz + the display pipeline; don't over-optimise it.
- **Board buttons (AtomS3R).** The 0.85" screen IS a programmable button (press the face); plus a
  side reset button, the 9-axis IMU (shake/tilt as pseudo-inputs), and the broken-out GPIO. Enough
  to build the one-time pairing-registration interaction (hold the screen to enter "find a remote"
  mode) with no added hardware.
- **Screen refresh rate — no published spec; design for 60 fps.** M5Stack's product page and m5-docs
  list the panel only as 0.85" IPS / 128×128; neither states a refresh rate. The driver is **GC9107
  over SPI**, whose internal frame-rate-control default is ~60 Hz (typical for these small TFTs;
  changeable via its FRC registers but rarely touched). 60 Hz is therefore the *visible* ceiling — you
  cannot display anything smoother, and we can hit it. If a register-exact number is ever needed (e.g.
  to drop to 30 Hz for power saving), it lives in the GC9107 datasheet + M5GFX's panel config, not in
  any M5Stack spec sheet.
- **The water-fill hold HUD ports to the board and runs at a full 60 fps — the fluid math is not the
  bottleneck.** Frame budget at 60 fps is 16.6 ms; the animation costs well under 2 ms of CPU:
  - *Surface* — the sum-of-sines (`HoldProgressHUD.swift`'s 4 waves) is 4 `sinf` per column × 128
    columns = 512 evals/frame. The S3 has a hardware single-precision FPU; this is nothing. Float is
    fine — no need for fixed-point or a sine LUT (a 256-entry LUT would add margin but isn't required
    at this scale).
  - *Fill* — 128×128 = 16 K pixel writes into an in-RAM framebuffer; pure memory, sub-millisecond.
  - *Push* — one full frame is 128×128×16bit = **32 KB**; over SPI at 40 MHz that's ~6.5 ms, but it
    runs on **DMA**, so the CPU is free to compute the next frame while it transfers. This 6.5 ms is
    the real cost and it's async, so the 60 Hz panel — not our pipeline — is the cap.

  Build it the right way or it drops to single-digit fps: **draw into an `M5Canvas` / sprite in RAM
  and `pushSprite` once per frame** (DMA-backed) — never write pixels straight to the panel in a loop;
  blocking per-pixel writes are the classic mistake. The genuine porting work is *appearance, not
  performance*: the Mac version gets the glass vessel, the water gradient, and the anti-aliased
  surface line for free from CoreAnimation's GPU compositor; on the board every one of those is
  hand-shaded into the framebuffer. That's more code, but it's still cheap memory math — 60 fps holds.
  (See the Tier 0 HUD section's "double-buffer / redraw only what changed" notes, which this confirms
  with numbers.)
- **On the power button specifically:** on the hardware path, map the remote's Power to any ORDINARY
  USB key rather than the system power key, and the whole loginwindow mess (long-press → macOS
  shutdown dialog, uninterceptable in userspace) simply never arises — the host never sees a power
  button.
- **Dev environment is installed and verified on this Mac — do NOT redo it.** ESP-IDF **v5.3.2** at
  `~/esp/esp-idf` (chosen for mature ESP32-S3 + NimBLE + TinyUSB support), toolchain
  `xtensa-esp-elf 13.2.0` and an isolated Python venv (`~/.espressif/python_env/idf5.3_py3.14_env`,
  which sidesteps the too-new system Python 3.14) both installed via `install.sh esp32s3`. Activate
  with `get_idf` (alias added to `~/.zshrc`) or `. ~/esp/esp-idf/export.sh`. Verified end-to-end: the
  `hello_world` example built to a real esp32s3 image (`idf.py set-target esp32s3 && idf.py build`).
  So when the boards arrive, the flow is just `idf.py -p <port> flash monitor` — no environment work.
  Command-line ESP-IDF was chosen over the Arduino IDE deliberately: better control over the bonding
  parameters and the composite USB device, and it lets the assistant run build/flash/monitor directly
  rather than driving a GUI.

## Settled — IOHID never hands over raw touch reports

**Resolved 2026-07-21. MultitouchSupport is the only way to read the clickpad on macOS.**

The two earlier "zero frames from the digitizer" results were worthless as evidence, and so were
two further attempts on the day: the window was started in the same instant the instruction was
sent, so it expired while the user was still reading. Every one of those runs captured zero frames
on EVERY interface, including the button interface that is known to work — which is the tell that
the setup, not the finding, was at fault.

The run that counts used a control group and no time pressure: all seven interfaces seized, raw
input-report callbacks registered, a five-minute window, and the user asked to first press a button
(control) and then slide a finger across the pad without pressing.

Result: **20 frames, every one from `0x0C/0x01`** (buttons — `fb 10 00`, `fb 08 00`, each with its
release), and **zero from `0x0D/0x01`** while the pad was being slid on. The probe demonstrably
worked; the touch reports simply never arrive.

So macOS routes clickpad data exclusively to Apple's multitouch stack, and seizing the digitizer
interface does not change that. Consequences:

- `TouchHandler`'s dependence on the private `MultitouchSupport` framework is not a shortcut that
  could be replaced by IOHID — it is the only option.
- Absolute coordinates are NOT lost, though — a correction to what this file used to say. That
  claim conflated two things: IOHID gives no touch reports (true), therefore absolute position is
  unavailable (false). `MTTouch.normalizedVector.position` IS an absolute position, 0…1 across the
  pad, not a relative stream; `TouchHandler` merely differentiates it into deltas to drive the
  cursor. Fixed zones, edge sliders and handwriting are all buildable on macOS. (They were rejected
  for ergonomic reasons — the pad is small and sliding on it is unpleasant — which is a separate and
  still-valid objection.)
- `MTTouch.absoluteVector` adds nothing: measured against the 2775×2775 (0.01 mm) surface it is
  exactly `normalized × 27.75 − 1.0` on both axes, to within 0.002 mm across every sample. It is the
  same position in millimetres with a 1 mm inset.
- Fields the struct carries and `TouchHandler` has never read, all measured to hold real data:
  `majorAxis`/`minorAxis` (contact ellipse, ~10.4 × ~8.4 mm — a firm press flattens the finger, so
  potentially a better press signal than `zTotal`), `zDensity`, `state` (MakeTouch/Touching/
  BreakTouch — press and release are currently *inferred* from contact counts instead), and
  `fingerID`/`pathIndex` for per-finger tracking. `angle` is a constant π/2 and carries nothing.
  `--dump-touches` prints all of them for the first 40 frames.

Methodology note worth keeping: when a test needs the user to do something physical, never start
the capture window in the same message that asks for it, and always include a positive control
whose absence proves the rig is broken rather than the hypothesis confirmed.

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

## Open threads, as of 2026-07-21 (updated 2026-07-23)

Nothing here is broken; these are decisions and unfinished lines of work.

**Shipped 2026-07-23 but NOT yet verified by a human on the real remote** — committed because the
build is green and the 92 core tests pass, but the app-layer gesture machine and the HUD animation
are not screenshot-verifiable (input timing and motion don't show in stills). The user will try the
feel that evening; if any of these is wrong, this is where to look:

- **Tap-then-hold (`.taphold*`) on the Back button.** New gesture in the most bug-prone file
  (`RemoteInputHandler`, see "The bug class this codebase keeps producing"). Verify, on the real
  remote: tap Back = one Delete; plain hold = auto-repeating Delete; tap-then-hold = the close-window
  (0.5s) / quit-app (1.2s) water HUD; a plain hold must NOT open that menu (the two must not blur);
  releasing a tap-then-hold before the first stage just deletes; no stuck keys after rapid use; and
  an ordinary `.hold` on ANOTHER key (Play/Pause hold → open Music, ring-down hold → minimise) still
  works, since `armHoldStages` was extracted and could have regressed them.
- **The hold-progress HUD is now a square water vessel** (`HoldProgressHUD.swift`, full rewrite):
  fills per stage, flushes empty + swaps icon between stages, overflows (grey) at the cancel stage.
  The surface is a sum-of-sines fluid (four non-harmonic waves + drift + jitter) after a height-field
  physics attempt was rejected for looking either too big/slow or dead-flat. Verify it reads as clean
  moving water, not a mechanical sine and not the wobbly physics version.
- **`autoRepeatDelay` decoupled to 0.3s** (was `holdThreshold`, 0.5s) — held-Delete should start
  repeating sooner now. Purely a feel change.
- Config changes riding along (all in `~/.config/siriremote/config.jsonc`, NOT in git): Back is now
  tap=Delete / hold=repeat-Delete / taphold=close+quit everywhere (terminal's old `repeatKey` and the
  global `.hold`/`.hold2` removed; browser keeps Cmd+[ back on tap); L1 Back falls back to Delete; L1
  double-ring-left/right switch Space; mute is global system-mute again (Music's `set mute` throws
  9038 on current Music.app, so the Music-mode override was dropped). `examples/config.jsonc` was NOT
  re-synced to these — decide whether to before anyone leans on it as the reference.

**Waiting on a decision from the user**

- **Is the microphone still wanted?** The protocol was never the unknown —
  `azais-corentin/siri-remote` targets this exact generation: enable byte `0xAF`, audio as wire
  report `0xFA` carrying 99-byte Opus (CELT-only WB, TOC `0xB8`, 48 kHz mono, 20 ms/frame), streamed
  only while the Siri button is held. **And as of 2026-07-23 macOS is no longer the blocker either:**
  dissecting the shipping `RemotePilot.app` gave us the full pure-Mac recipe (enable HCI logging via
  `com.apple.MobileBluetooth.debug → HCITraces{HCISkipAuth,RawAudioTrace}` + restart bluetoothd,
  capture with PacketLogger, reassemble, Opus-decode, Speech→CGEvent) — ad-hoc signed, public
  entitlements, no ESP32/Linux. See "Microphone — SOLVED on macOS (2026-07-23)". So the mic **no
  longer gates** the ESP32/Linux threads; those are now wanted only for the *own-it / no-admin /
  no-PacketLogger* reasons, not because they are the sole path. Decision left to the user: reproduce
  the pipeline in our own app, just run RemotePilot/CouchVox, or defer.
- ~~**Licensing.**~~ **Settled 2026-07-22.** Relicensed to **GPL-3.0-or-later** ahead of going
  public; the plan to sell it was dropped. The upstream MIT notice (© 2026 Jinsoo An) is retained in
  `NOTICE`, which MIT requires and GPL relicensing does not waive. This was not optional: a
  line-survival measurement against the fork-point commit `41e5ca1` found **6,691 of 11,833 current
  lines (56.5%)** still attributable to the import, concentrated in exactly the native layer the
  README credits upstream — `MenuBarManager` 100%, `MultitouchSupport.h` 100%, `RemoteView` 100%,
  `LayoutView` 98%, `RemoteDetector` 92%, `MediaController` 91%, `TouchHandler` 80%. The import was
  squashed, so that figure is an UPPER bound (it also contains pre-first-commit work of our own) and
  the true upstream share cannot be recovered from this repo — which is precisely why the notice
  stays. Relicensing is still clean only while there is one copyright holder; the first outside
  contribution ends that.
- **A Windows port.** Deliberately parked. Two facts already gathered: Windows blocks output reports
  to *keyboard* HID devices, which this remote is not (Consumer Control + Digitizer), and it does
  grant apps GATT access after pairing. Unverified: whether its HOGP bridge preserves real report
  IDs (macOS rewrites them) and whether `0x1812` is enumerable. A 20-minute probe on the user's
  Windows machine answers all three; do that before porting anything.

**Waiting on hardware**

- The 2× AtomS3R **shipped and are due Tuesday 2026-07-28**. First milestone is deliberately small:
  connect, bond, and dump the full GATT database with handles. Everything else is guesswork until that
  output exists. Biggest unknown is bonding — HOGP mandates an encrypted link and Apple peripherals
  are fussy about it. Dev environment is already installed and verified (ESP-IDF v5.3.2, `get_idf`),
  so day one is `idf.py -p <port> flash monitor`, not setup. **Firmware code quality is a hard
  requirement, not a nicety — see the callout under "Future direction" before writing any of it.**

**Unfinished but self-contained**

- **Brightness does not come back the next morning** — see that section; still unreproduced.
- **The second machine** (a MacBook Air reached over Tailscale) has an install from earlier on
  2026-07-21 and is behind. It has Command Line Tools but no full Xcode, so `swift test`
  cannot run there (no XCTest); building is unaffected. Sync with rsync + rebuild, in separate
  steps — the link has dropped mid-build before.
- **The Z band is unused.** `--touch-monitor` shows the clickpad reports a clean, graded hover
  signal: an approaching finger rises monotonically from ~0.08 to contact at ~0.5 over ~40 frames,
  and it registers before first contact, not only after lift-off. Nothing acts on it. Its useful
  range is a few millimetres, which is the same constraint that killed the zone-based ideas.
- **Contact ellipse and touch state are unused.** `majorAxis`/`minorAxis` (~10.4 × ~8.4 mm) and the
  MakeTouch/Touching/BreakTouch state machine both carry real data; press and release are currently
  *inferred* from contact counts instead.

## Maintenance rules

- Preserve user changes and the active config; do not reset or replace mappings without explicit
  permission.
- After source changes: run core tests, build the app, package it, relaunch it, and inspect the log.
- After every diagnostic: restore exactly one no-argument HyperVibe instance and verify that it is
  running. Do not end a debugging session while the app is stopped or duplicated.
- Keep experiments behind command-line flags and off by default.
- Record exact commands, IOReturn values, report IDs/sizes, and whether the user completed the
  physical Siri-button step. Do not upgrade hypotheses to facts without captured data.
- Update this file and the relevant detailed document before ending an investigation session. It
  drifts fast: a session that adds a feature and a resolution rule but not the paragraph describing
  them leaves the next reader with a file that is confidently wrong.
- Press-scoped teardown goes in `endPressScopedWork`, never alongside it. Three separate times a
  feature added press-scoped state and the next path to skip a release leaked it — see the bug-class
  section. The same applies to resolution: add to `Controller.site(_:)`, not around it.
- Measure UI geometry and timing from a screenshot or a log, not from reasoning. Several confident
  fixes in this file's history were wrong, and the wrongness was only visible in pixels: an icon
  centred on a reconstructed line box, a press detector that fired after the click it meant to
  pre-empt, a Space "switch" that moved the bookkeeping and 568 of 20,358,144 pixels.
- When a test needs the user to do something physical, never start the capture window in the same
  message that asks for it, and always include a positive control whose absence proves the rig is
  broken rather than the hypothesis confirmed.
