# SiriRemoteForge — living handoff

Last updated: 2026-08-29 (Australia/Sydney)

This document is the concise source of truth for continuing development. Keep it updated whenever
the architecture, user-facing mappings, build/run workflow, or microphone investigation changes.
The detailed product and configuration reference remains in `README.md`; microphone experiments
belong in `docs/mic-reverse-engineering.md`.

## Repository and runtime state

### Non-negotiable local App deployment invariant

- Every compiled and packaged user-test build must be installed as
  `/Applications/HyperVibe.app`. Do not run the workspace copy at `app/HyperVibe.app` as the live
  App.
- Local builds must preserve the existing stable `siriRemote Local Signing` identity. Verify that
  signature before replacing the installed App; if it is missing or invalid, stop. Never silently
  fall back to ad-hoc signing, because its changing code identity makes macOS request Accessibility,
  Input Monitoring, Microphone, and Automation permissions again.
- Restart only after the installed bundle passes signature verification, then verify there is one UI
  process and that it runs from `/Applications/HyperVibe.app/Contents/MacOS/HyperVibe`.
- These rules are also recorded in the repository-root `AGENTS.md` so future coding sessions inherit
  them before changing or deploying the App.

- Canonical repository: `https://github.com/HOLODATA-COM/SiriRemoteForge`, branch `main`.
  **GPL-3.0-or-later** as of 2026-07-22, going public; the paid-release plan was dropped. Upstream's
  MIT notice is retained in `NOTICE` — see the licensing note at the end for why that is mandatory.
- Local checkout: the repository root (`siriremote-release`).
- Current committed HEAD: `c39f300` (`docs(release): detail beta.5 UI redesign`; history-rewritten
  equivalent with Claude co-author trailers removed from public refs).

### ⚡ LATEST — 2026-08-29: Sci-fi Voice edge cues + transactional personal dictionary (uncommitted, tested, deployed)

- Native Voice now uses the exact UI SFX **Sci-fi Toggle on** cue when a real dictation turn opens
  and **Sci-fi Toggle off** after capture closes. Both official MP3s are preloaded off the press
  path into dedicated `AVAudioPlayer`s; rewinding still prevents duplicated HID edges from stacking
  playback, and the existing JSON volume setting remains authoritative. Capture/meter suppression
  is bounded at 0.30 s to exclude the audible cue without discarding the official MP3's nearly
  silent encoder/reverb tail. Installed SHA-256 values are
  `2f5ac451e043c08e23d14fe1bda7555ed8a627a469e834ab4300279ffe4ea135` (on) and
  `598186c2d47cb0c970a450ef3943521b6e07b20fd506edde9b401d30cc115fc1` (off).
- App packaging now copies the complete nested `app/Resources` tree and fails if either cue or its
  license is absent. UI SFX audio is CC0-1.0; attribution/source text is embedded at
  `Contents/Resources/Sounds/UI-SFX-LICENSE.txt` and recorded in the repository `NOTICE`.
- Personal Dictionary remains one JSON-backed source of truth for transcription keywords/prompts,
  deterministic Final correction and cleanup. Settings now presents readable term rows and a
  draft-first Add/Edit sheet with autofocus, duplicate detection, optional aliases, comma/Chinese
  comma/semicolon/newline parsing, deduplication, edit and delete. Invalid half-typed terms never
  reach the live config; a confirmed edit is written once and auto-saved to `config.jsonc`.
- The live configuration retains `HyperVibe` and adds `clique`, `sub-agent`, `审稿人`, `SIGMOD` and
  `VLDB`, with conservative spelling aliases for the English terms. The pre-change config is
  recoverable at `/private/tmp/hypervibe-config-before-dictionary-20260829.jsonc`.
- Verification: warning-free optimized build; SiriRemoteCore **134/134**; packaged native Voice
  self-test **66/66** (`dictionary=3.63 ms`, PCM 10 s `0.27 ms`, Realtime envelopes 10 s `0.19 ms`);
  official installed audio hashes; `git diff --check`; and candidate/staged/installed deep-strict
  signature verification using the unchanged stable Designated Requirement. Stable build
  **`1.0.0-local.19`** is installed only at `/Applications/HyperVibe.app`, with exactly one UI
  process from that path (PID **56881**). local.18 is recoverable at
  `/private/tmp/HyperVibe-before-scifi-local18.app`. Nothing was committed or pushed.

### ⚡ LATEST — 2026-08-29: No cleanup word blacklist + 1 s recording gate (uncommitted, tested, deployed)

- Removed every natural-language keyword/prefix heuristic from the local cleanup validator. Words
  such as `best`, `Sure`, `好的`, `没问题`, or any future vocabulary are ordinary dictated content;
  no word can independently classify text as an assistant response. Safety still comes from the
  system/user role boundary, typed JSON source envelope, provider prompt contract, language-neutral
  length/content grounding, and preservation of question-mark structure.
- Added explicit local and real-cloud regressions proving `Sure here is the best option` and
  `好的没问题我现在就来处理` remain valid transcript content. The DeepSeek suite now covers six
  fixed, non-private cases: those two legitimate phrases plus Chinese/English questions, a request,
  and a prompt-injection question. All six used actual cloud cleanup rather than the local fallback.
- The default and live `settings.dictation.minimumRecordingSeconds` are now **1.0 s**. Audio below
  one second remains local and produces no upload, cleanup, insertion, history entry or error; the
  exact one-second PCM boundary is accepted. Defaults, README, both example JSON files, GUI-backed
  config and regressions agree.
- Headless SF Symbol regression setup now creates a prohibited `NSApplication` and runs on the main
  actor; the test still requires execution outside Codex's WindowServer-restricted sandbox, but no
  longer touches AppKit from a background executor.
- Verification: SiriRemoteCore **134/134**; packaged native Voice self-test **66/66**
  (`dictionary=3.78 ms`, PCM 10 s `0.27 ms`, Realtime envelopes 10 s `0.19 ms`); real DeepSeek
  guardrails **6/6 in 4125 ms total**; warning-free optimized build; `git diff --check`; and
  candidate/staged/installed deep-strict signature verification. Stable build
  **`1.0.0-local.18`** is installed only at `/Applications/HyperVibe.app`; existing Input
  Monitoring remains granted, and exactly one UI process runs from that path (PID **23228**).
  local.17 is recoverable at
  `/private/tmp/hypervibe-before-no-blacklist.ynrVhj/HyperVibe-installed-local17.app`; the prior live
  config is at `/private/tmp/hypervibe-before-prompt.uVSOKh/config-before-minimum-1.jsonc`. Nothing
  was committed or pushed.

### ⚡ LATEST — 2026-08-29: Final cleanup cannot answer the transcript (uncommitted, tested, deployed)

- OpenAI and DeepSeek no longer receive dictated text as an ordinary free-form user message. The
  source is JSON-escaped inside a typed `untrusted_voice_transcript` envelope, while the system
  instruction defines it exclusively as quoted data to edit, including when it addresses the
  model, asks a question, requests an action, contains prompt/role text, or attempts instruction
  override.
- The cleanup contract is now speech-act preserving: a question remains the speaker's question; a
  request or command remains addressed to its intended recipient. The model must never answer,
  comply, solve, summarize, continue the conversation, acknowledge, preface, or invent content.
  Explicit numbered speech and dictionary correction remain supported. DeepSeek cleanup also uses
  deterministic temperature zero.
- HTTP success is no longer trusted by itself. A conservative local guard rejects newly introduced
  assistant-style prefixes, questions changed into statements, lost request intent, extreme length
  changes, and output insufficiently grounded in the original English/CJK content. Rejection keeps
  the already-valid transcript rather than typing a model reply.
- Verification: warning-free optimized build; native Voice regression exit success with **64**
  checks; `git diff --check`; and four real DeepSeek guardrail cases (Chinese question, Chinese
  request, prompt-injection question and English question) all passed as actual cloud cleanup rather
  than local fallback in **3152 ms total**. Candidate, staged bundle and installed bundle passed
  deep/strict signature verification using the stable identity. Build **`1.0.0-local.17`** is
  installed only at `/Applications/HyperVibe.app`, Designated Requirement remains
  `identifier "com.hypervibe.app" and certificate leaf =
  H"80f746bd1de5a7ceb835a200ce4e43705f01aee6"`, and exactly one UI process runs there (PID
  **7577**). local.16 is recoverable at
  `/private/tmp/hypervibe-before-prompt.uVSOKh/HyperVibe-installed-original.app`. Nothing was
  committed or pushed.

### ⚡ LATEST — 2026-08-29: Final Voice insertion repaired for Chrome/web editors (uncommitted, tested, deployed)

- The failure was reproduced in **Final**, not External: runtime logs showed
  `settings.dictation.activeMode = final`, Chrome frontmost, and a four-second Voice hold. The old
  Final chain tried `AXSelectedText` first. Chromium contenteditable controls can report that write
  as successful without dispatching the DOM `input` event, so HyperVibe stopped before reaching the
  same Command-V path that worked manually.
- Final delivery now uses a guarded clipboard transaction first, followed independently by AX and
  Unicode event fallbacks. It rechecks the original app/focus, Secure Input and secure-field state
  immediately before mutation; optionally restores every clipboard item/type only while its private
  marker and `changeCount` prove the transaction still owns the clipboard. Streaming remains a
  direct, clipboard-free delta path.
- Diagnostics record only bundle/role, selected-text capability, route and outcome; dictated text is
  never logged. A production-inert `--test-voice-final-delivery` probe exercises the exact Final
  delivery chain with fixed non-secret text.
- Verification: packaged native Voice self-test **60/60**; `git diff --check`; stable-signed
  candidate/stage/installed deep-strict verification before replacement; and an isolated Chrome
  profile with a disposable `textarea` confirmed both the inserted fixed text and a real DOM
  `input` event (`PASS — REAL INPUT EVENT RECEIVED`). Stable build **`1.0.0-local.16`** is installed
  only at `/Applications/HyperVibe.app`; its Designated Requirement remains
  `identifier "com.hypervibe.app" and certificate leaf =
  H"80f746bd1de5a7ceb835a200ce4e43705f01aee6"`. The pre-change local.15 App is recoverable at
  `/private/tmp/hypervibe-before-chrome-paste.rYoS1J/HyperVibe-local15.app`. Exactly one normal UI
  process now runs from the required `/Applications` path (PID **76174**). Nothing was committed or
  pushed.

### ⚡ LATEST — 2026-08-29: Voice aperture motion, 2 s gate, structured lists, and rebuilt-editor delivery (uncommitted, tested, deployed)

- The independent lower-centre Voice capsule no longer fades in/out generically. Capture opens from
  a centre phosphor point into a horizontal scan line, then a shallow band and the complete fixed-size
  material surface in **205 ms**. Exit reverses through a full-width scan line to a centre point in
  **155 ms**. The actual panel frame never resizes. Waveform bars originate at the capsule centre;
  the scan-line glow, border and icon are choreographed on the same Core Animation clock.
- `settings.dictation.minimumRecordingSeconds` is now a JSON/UI setting (default **2.0 s**, JSON
  validation 0...30 s and never above `maxRecordingSeconds`). Duration uses actual captured 24 kHz
  PCM frames, not button/timer estimates. Before the exact gate, audio remains only in the local
  unbounded capture buffer: the prepared Realtime socket receives no microphone bytes and Streaming
  inserts nothing. At the gate, the complete buffered prefix drains to the warm socket, preserving
  the first word. Releasing below the gate closes capture/capsule silently with no upload,
  transcription, cleanup, insertion, history mutation, or error card.
- Final cleanup now explicitly preserves a dictated introduction and recovers spoken enumerations
  (`one/two/three`, `first/second`, `一、二、三`, `第一/第二…`) as consistent `1.`, `2.`, `3.` lines.
  It is instructed not to turn ordinary prose into a list and still returns text only.
- Voice delivery no longer assumes a long-lived Accessibility object is stable. React/Electron
  editors such as the Codex/Claude composer can rebuild the same visible AX node while recording;
  the old identity-only guard wrongly classified that as `focusChanged`, so Final copied instead of
  inserting. Delivery now accepts only a semantically editable replacement with a matching stable
  AX identifier or matching role/placeholder plus at least 58% geometric overlap. Frontmost PID,
  Secure Input and secure-field checks remain mandatory, and a genuinely different field in the
  same app remains rejected.
- Verification: SiriRemoteCore **134/134**; packaged native Voice self-test **59/59**
  (`dictionary=3.52 ms`, PCM 10 s `0.26 ms`, Realtime envelopes 10 s `0.18 ms`); warning-free
  optimized App build; `git diff --check`; deep/strict candidate, staged and installed signature
  verification; and a 120 fps visual pass of both aperture directions. Stable build
  **`1.0.0-local.15`** is installed only at `/Applications/HyperVibe.app`; its Designated
  Requirement remains `identifier "com.hypervibe.app" and certificate leaf =
  H"80f746bd1de5a7ceb835a200ce4e43705f01aee6"`. Exactly one UI process runs from the required path
  (PID **58212**). The pre-change local.14 App is recoverable at
  `/private/tmp/hypervibe-before-voice-fixes.2CJ1Tr/HyperVibe-original.app`. Nothing was committed or
  pushed.

### ⚡ LATEST — 2026-08-28: Voice is global across Layers + hardware mode chord (uncommitted, tested, deployed)

- Voice routing is now orthogonal to the configurable Layer stack. One authoritative
  `settings.dictation.activeMode` (`external`, `final`, or `streaming`) applies on every Layer;
  changing Layer can no longer silently change the side-button pipeline. Old configurations that
  lack `activeMode` migrate deterministically from their legacy global `outputMode`, while legacy
  `layerModes` remain decodable for downgrade compatibility but are ignored and cleared on the next
  explicit mode selection/save.
- Hold **Mute** and tap the **Side/Voice** button to cycle **External → Final → Live → External**.
  The chord is recognized directly on the physical Side-down edge with no timer and therefore adds
  no latency to an ordinary Side hold. Its own mode switch is silent; the existing matched begin/end
  cues for an actual native dictation turn are unchanged. Both native transports remain prewarmed
  even while External is selected, so the next native turn does not pay a new socket handshake.
- The always-on status widget confirms all three choices through a 240 ms, fixed-size, depth-turn +
  three-orbit animation and returns to the current Layer. Final and Live also animate an independent
  lower-centre Voice capsule; **External never creates that Voice capsule** and dismisses an existing
  selector preview. Real capture/delivery always takes presentation priority over a selector preview.
  All three selector symbols are JSON-configurable through `voice.mode.external`,
  `voice.mode.final`, and `voice.mode.streaming`.
- Settings → Voice now has one global three-way selector and mode-specific explanations instead of
  a per-Layer routing matrix. Final-only cleanup controls remain conditional. README, both example
  configurations, defaults, localisation, migration tests, and the native self-test describe the
  same global model.
- Independent review found and closed one important teardown edge: after the chord takes ownership,
  any already-open external/native PTT is paired closed, a held repeat receives key-up, and a
  momentary Layer is unwound before both physical releases are consumed. The cleanup is idempotent.
  Accepted custom-config constraint: an exotic Mute mapping that deliberately executes on its
  initial press edge (`repeatKey`, or PTT held beyond its opener delay) can act before a later Side
  press exists to identify the chord; teardown prevents any latched state. The shipped Mute mapping
  is release/multi-tap-disambiguated and has no such leak.
- Verification: warning-free optimized App build; SiriRemoteCore **134/134**; packaged native Voice
  self-test **52/52** (`dictionary=3.84 ms`, PCM 10 s `0.26 ms`, packet construction `0.19 ms`);
  `git diff --check`; deep/strict stable-signature verification before and after installation; and
  candidate/installed executable SHA-256 equality. Stable build **`1.0.0-local.14`** is installed
  only at `/Applications/HyperVibe.app`. Its Designated Requirement remains
  `identifier "com.hypervibe.app" and certificate leaf = H"80f746bd1de5a7ceb835a200ce4e43705f01aee6"`;
  credential-helper CDHash remains `13d5c95754534f4fcc26799385d9f48b8ac8c544`. Exactly one UI
  process runs from the required path (PID **31020**) and Host PID **906** was preserved. Build 12 is
  recoverable at `/private/tmp/HyperVibe-installed-before-global-voice-build13.backup`; build 13 is
  recoverable at `/private/tmp/HyperVibe-installed-before-teardown-fix-build14.backup`. Nothing was
  committed or pushed.

### ⚡ LATEST — 2026-08-28: Final Voice omits the Inserting card (uncommitted, tested, deployed)

- User Layer 2 (`L1`, Final mode) now presents exactly **Listening → Transcribing → Polishing →
  Inserted / Copied / Error**. It no longer opens a separate `Inserting` card for the normally
  millisecond-scale delivery step. Both the persistent status widget and independent Voice capsule
  receive the same compressed live phase sequence.
- This is presentation-only. Final text delivery still records insertion latency and retains the
  complete guarded chain: captured-target validation, native AX selected-text replacement,
  compatibility paste with optional clipboard restoration, Unicode fallback, secure-field/focus
  rejection, and copy-on-failure. Streaming behavior is unchanged.
- `VoiceDictationPresentationPolicy.showsInsertionProgress` now explicitly returns false for both
  modes, and the native regression suite asserts the live Final sequence is monotonic without
  `Inserting`. SiriRemoteCore passes **134/134**; the optimized App compiles cleanly; packaged Voice
  self-test passes **48/48** (`dictionary=3.43 ms`, PCM 10 s `0.29 ms`, packet construction
  `0.19 ms`); and `git diff --check` passes.
- Stable build **`1.0.0-local.12`** is installed only at `/Applications/HyperVibe.app`. Deep/strict
  verification and the unchanged certificate-bound Designated Requirement pass; credential-helper
  CDHash remains `13d5c95754534f4fcc26799385d9f48b8ac8c544`, and both Voice credentials load
  without a prompt. Exactly one UI process runs from the required path (PID **11393**) and Host PID
  **906** was preserved. Build 11 is recoverable at
  `/private/tmp/HyperVibe-installed-before-no-inserting-build12.app`. Nothing was committed or
  pushed.

### ⚡ LATEST — 2026-08-28: Voice capsule follows the pointer's display (uncommitted, tested, deployed)

- The independent Voice pipeline capsule now chooses the display containing the mouse pointer at
  the beginning of every native Voice turn and anchors at that display's lower centre. It remains
  draggable for the current turn only. A new turn, a pointer transition to another display, or a
  display-configuration change resets it to the lower centre of the newly relevant display; moving
  the pointer within one display does not make the capsule chase it.
- Cross-display detection runs on the main run loop every **60 ms** only while the capsule is
  visible. It compares display IDs before doing any window/material work, pauses while the user is
  dragging, and invalidates the timer as soon as the panel orders out. Dragging within the current
  display therefore remains stable; dragging or moving the pointer across a display boundary
  converges to the new display's default anchor without changing panel size.
- `VoicePipelineScreenPlacement` keeps display hit-testing and lower-centre geometry pure and
  independently testable. The native Voice self-test is now **48/48**, including two-display
  selection and offset-coordinate anchor regressions; the packaged run measured a 500-term
  dictionary at **3.69 ms**, ten seconds of PCM conversion at **0.27 ms**, and packet construction
  at **0.18 ms**. SiriRemoteCore remains **134/134**, the optimized App build is warning-free, and
  `git diff --check` passes.
- Stable build **`1.0.0-local.11`** is installed only at `/Applications/HyperVibe.app`. Deep/strict
  verification passes with the unchanged requirement `identifier "com.hypervibe.app" and
  certificate leaf = H"80f746bd1de5a7ceb835a200ce4e43705f01aee6"`; the credential-helper
  CDHash remains `13d5c95754534f4fcc26799385d9f48b8ac8c544`. Both existing Voice credentials
  load without a prompt. Exactly one UI process runs from the required path (PID **8183**) and the
  existing Host remains PID **906**. Build 10 is recoverable at
  `/private/tmp/HyperVibe-installed-before-pointer-screen-build11.app`.
- `create_app_bundle.sh` no longer puts the dedicated signing-keychain password in process argv.
  A locked keychain must be unlocked through the native macOS secure prompt; the build still stops
  rather than falling back to ad-hoc signing if the stable certificate/private-key identity is not
  available. Nothing was committed or pushed.

### ⚡ LATEST — 2026-08-28: Streaming success returns directly to Layer (uncommitted, tested, deployed)

- Layer 3 remains true live insertion: the first transcript delta reaches the captured caret
  immediately and later fragments retain the 8 ms coalescing window. On physical release, a
  successful Streaming turn now closes the real waveform and returns directly to the current Layer.
  It never presents the Final-only `Transcribing`, `Inserting`, or `Inserted` cards while the
  authoritative committed suffix is reconciled silently in the background.
- Attention states are deliberately unchanged: clipboard fallback still presents `Copied`, while
  focus changes, secure fields, unavailable delivery and network failures still present `Error`.
  Final mode retains its complete visible sequence.
- A shared `VoiceDictationPresentationPolicy` owns these mode/outcome decisions, with three new
  headless regression checks preventing the Final and Streaming presentations from converging
  accidentally. Installed self-test is **43/43**; SiriRemoteCore remains **134/134**.
- Stable build **`1.0.0-local.6`** is installed at `/Applications/HyperVibe.app`; its existing
  certificate-bound DR and credential-helper CDHash are unchanged. Exactly one UI process runs from
  that path (PID **60089**), Host PID **906** was not restarted, both Keychain credentials load, and
  the live JSON config is byte-for-byte unchanged. Recoverable build 5 App/config copies are in
  `/private/tmp/hypervibe-streaming-clean-exit-backup.lE1oSW/`. Nothing was committed or pushed.

### ⚡ LATEST — 2026-08-28: JSON-owned icons + Voice hot-path hardening (uncommitted; reviewed, tested, deployed)

- Ordinary binding symbols now come directly from each JSON action's `icon`, inheriting field by
  field through the normal mode chain. Two truthful exceptions are enforced before that static
  presentation: volume/brightness always render the measured variable system state, and actions
  that launch/open an App always discover its installed real icon. Invalid or unavailable symbols
  fall back without leaving a blank slot.
- Every ordered Layer accepts `settings.layers[].icon`. Non-binding status symbols are portable in
  `settings.icons`: `layer.default`, remote connected/disconnected, six native Voice result phases,
  and `fallback`. One shared resolver validates every level independently in the exact chain
  **Layer icon → layer.default → JSON fallback → built-in**; an unsupported symbol on an older macOS
  cannot swallow a valid later choice. Layer/connection HUD, persistent widget, Voice Settings rows,
  defaults and both examples use the same data and hot-reload together. The Layout Add Layer sheet
  also accepts an optional SF Symbol name.
- The live config was changed minimally: the three existing Layers received their current stack
  symbol explicitly and the complete `settings.icons` map was inserted. No action, timing, curve,
  Voice route, or other saved setting changed. The pre-change JSON is recoverable beside the App
  backup below.
- Independent latency/concurrency review found no remaining P0/P1. Its earlier five P1 findings are
  closed: the begin cue is excluded from capture/metering; permanent socket failures stop until the
  relevant credentials/settings change while transient failures use exponential jittered backoff;
  Voice text-field reconnects are debounced; a quick side-button tap no longer checks out or destroys
  a warm socket; and CoreAudio/brightness sampling is cached and performed off the main thread.
  Quiet gated frames now release waveform peak normally, and Layout's Select/Touch native icons are
  semantic rather than generic.
- Accepted P2s: speaking deliberately during the 180 ms begin-cue exclusion may clip the first
  phoneme; the first uncached real App icon lookup may perform one synchronous Workspace/filesystem
  query. Neither affects later turns or first-token network latency.
- Verification: warning-free optimized build; `git diff --check`; SiriRemoteCore **134/134**;
  installed native self-test **43/43** (`PCM 10 s 0.32 ms`, packet construction `0.21 ms`, 500-term
  dictionary `3.67 ms` in the final run); both Keychain credentials load without a prompt; and two
  OpenAI Realtime sockets are established (plus the unrelated update/feed connection).
- Stable build **`1.0.0-local.6`** is installed only at `/Applications/HyperVibe.app`. Its DR remains
  `identifier "com.hypervibe.app" and certificate leaf = H"80f746bd1de5a7ceb835a200ce4e43705f01aee6"`;
  credential-helper CDHash remains `13d5c95754534f4fcc26799385d9f48b8ac8c544`. Exactly one UI
  process runs from the required path (PID **60089**) and Host PID **906** was not restarted.
  Recoverable pre-deployment App/config copies are in
  `/private/tmp/hypervibe-streaming-clean-exit-backup.lE1oSW/`. Nothing was committed or pushed.

### ⚡ LATEST — 2026-08-28: Voice route per Layer (uncommitted; reviewed, tested, deployed)

- The side button now resolves native Voice independently for each configured Layer through
  `settings.dictation.layerModes`: `inherit` follows the global fallback, `existing` leaves the
  ordinary JSON binding untouched, and `final` / `streaming` select their respective native paths.
  Missing `layerModes` remains backward compatible and follows the existing global `outputMode`.
- The live mapping is exactly **`BASE: existing` (user Layer 1), `L1: final` (Layer 2),
  `L2: streaming` (Layer 3)**. Master Voice is enabled. Layer 1 therefore retains its existing
  `button.siri: pushToTalk` and `.tap: Enter` behavior; native previous-transcript double-click is
  also scoped to native Layers and cannot steal Layer 1's quick-button behavior.
- Settings → Voice has a colour-keyed row for every configured Layer with **Use default / Keep
  existing / Final / Streaming**. All choices persist through JSON and hot reload. A session freezes
  its resolved mode at the physical press edge, so changing Layers mid-utterance cannot change an
  in-flight Final turn into Streaming.
- Final and Streaming keep separate prepared Realtime sockets. The number of warm sockets is capped
  by output mode (**maximum two**), not Layer count (maximum ten), eliminating a fresh handshake on
  the first press immediately after switching Layer without scaling resource use per Layer.
- Native Voice holds have a matched **86 ms begin/end sound pair**, enabled by default. Both cues
  are pre-rendered and played off the main thread; the end cue is scheduled only after capture has
  stopped, so it cannot leak into the utterance. `feedbackSoundsEnabled` and
  `feedbackSoundVolume` are available in both JSON and Settings. Layer 1 keeps its external
  push-to-talk path unchanged, including any feedback owned by that external workflow.
- The persistent widget now normalises real microphone levels against a hold-local adaptive peak
  after a true acoustic noise gate. The same voice produces comparable waveform travel in Layers 2
  and 3 even when the selected source/gain differs, without flattening syllable dynamics.
- Every action family resolves a concrete icon. Layout rows show an action/native fallback symbol,
  native dictation phases resolve their semantic SF Symbol at the final presentation boundary, and
  an unavailable user-authored symbol falls back to `command.circle.fill` instead of leaving an
  empty slot. The live Layer 2/3 bindings explicitly name Zoom, arrow, Delete, and Brightness
  symbols; a visual Layout snapshot confirmed that every displayed row has an icon.
- Verification: optimized App compiles without warnings; SiriRemoteCore **133/133**; native Voice
  self-test **32/32**; the frozen stable-signed candidate plus ten concurrent self-tests all passed.
  Ten seconds of PCM conversion measured **0.27–0.36 ms**, Realtime packet construction
  **0.18–0.21 ms**, and a 500-term dictionary **3.63–4.16 ms**. Harmless synthetic-audio live API
  checks passed: prewarmed Streaming first delta **597 ms from press**, final commit **745 ms after
  release**; the prewarmed Final route committed **1.061 s after release**. Final mode no longer
  sends the Streaming-only `delay: minimal` field, which OpenAI rejects for `gpt-transcribe` and
  which had caused a hidden reconnect cycle.
- Stable build `1.0.0-local.4` is installed only at `/Applications/HyperVibe.app`. Its Designated
  Requirement is unchanged, credential-helper CDHash remains
  `13d5c95754534f4fcc26799385d9f48b8ac8c544`, both Keychain credentials load without a prompt, and
  exactly one UI process runs from the required bundle. Existing Host PID 906 was never restarted.
  Recoverable pre-deployment backups are at
  `/private/tmp/hypervibe-layer-voice-icons-backup.74EYVe/` (the earlier build is also at
  `/private/tmp/hypervibe-layer-install-backup.jTOE0N/`). Nothing was committed or pushed.

### ⚡ LATEST — 2026-08-28: App-native low-latency dictation (uncommitted; reviewed, tested, deployed)

- **User behavior:** `Settings → Voice` enables native side-button dictation directly; it no longer
  depends on a hidden `button.siri: pushToTalk` mapping. Capture and the prepared OpenAI Realtime
  route begin on the raw press edge, Voice becomes visible only after the existing **0.2 s** hold
  discriminator, and release ends the live presentation immediately. A quick tap cancels silently
  and preserves an explicit `.tap` binding or the pre-existing base binding. When
  `copyLastOnSideButtonDouble` is enabled, a side-button double-click copies the previous dictation;
  disabling it restores the configured `.double` action.
- **Two intentionally separate paths:** Streaming inserts the first true delta immediately and
  coalesces later fragments for at most **8 ms**, with no LLM rewrite. Final uses `gpt-transcribe`,
  applies the cached on-device dictionary, then optionally polishes with OpenAI `gpt-5.6-luna` or
  DeepSeek `deepseek-v4-flash`. DeepSeek is the default cleanup provider because it measured faster;
  cleanup is fail-open to the deterministic transcript.
- **Capture/network hot path:** microphone demand, ring reading, AX target capture, credential
  lookup, and network preparation overlap from the physical press edge. Credentials are preloaded
  asynchronously and cached before input. The source probe prefers fresh remote voice, falls back
  to the pinned built-in microphone, and locks after 120 ms. The 48→24 kHz converter writes into
  pre-sized PCM memory; each 20 ms packet uses a fixed Realtime envelope. The optimized App uses
  `-O` plus whole-module optimization, keeps the OpenAI socket warm with 15 s pings, and prewarms
  cleanup-provider DNS/TLS/HTTP connections.
- **No polling or guessed completion:** Realtime readiness and final results use checked
  continuations with bounded timeout/cancellation, so there is no 5/10 ms polling tax. An ordered
  callback drain guarantees all deltas/previews have been consumed before reconciliation; the REST
  fallback starts in parallel with live-session cancellation/drain. A rejected handshake wakes the
  fallback immediately instead of consuming the former four-second wait. Final mode sends only its
  first delta to the UI thread for timing; Streaming forwards the first delta immediately.
- **Delivery safety:** target inspection runs off the main thread. HyperVibe captures the concrete
  focused AX editor before the HUD appears, then rechecks frontmost PID, Secure Input, and that AX
  element immediately before mutation. It tries native AX insertion, guarded paste, then Unicode
  CGEvents (with another guard every 20 UTF-16 units). Clipboard fallback is transactionally
  restored only if neither the user nor another app changed it. Streaming accepts only a strict
  missing suffix after commit; an unsafe revision is copied instead of duplicated. If an app exposes
  no focused AX element, macOS supplies no same-process editor identity to compare; PID and Secure
  Input guards still apply.
- **Settings/config:** all non-secret behavior is represented in `settings.dictation` and round-trips
  through JSONC/GUI: enable, Final/Streaming, models, language hints, cleanup provider, delivery
  fallbacks, double-click copy, duration, and a 500-entry canonical/alias dictionary. The embedded
  first-run template and both examples include the full schema. The Voice page exposes Keychain
  setup/tests and in-memory press-to-audio/session/delta/transcript/cleanup/insertion timings. The
  current live JSON explicitly enables Voice with the Layer-specific routing documented above.
- **Credentials/signing boundary:** keys never enter JSON, UserDefaults, argv, logs, bundle resources,
  or Git. A deterministic signed child helper owns login-keychain ACL service
  `com.hypervibe.credentials.v6`; App and helper mutually validate code identity. Its stable CDHash is
  **`13d5c95754534f4fcc26799385d9f48b8ac8c544`**. Treat `app/CredentialBroker/`,
  `CredentialKeychainBridge.*`, its fixed Info.plist, build flags, and nested signing order as an
  immutable compatibility boundary. Identifier-only ad-hoc public builds deliberately cannot read
  these credentials; public native Voice requires the future Developer ID signing workflow.
- **Final measured candidate:** a harmless synthetic-audio live OpenAI test, paced at real capture
  cadence, measured a prewarmed-session first delta at **594 ms from press** and committed final at
  **834 ms after release**. The **1.748 s** socket handshake happened during prewarm and is not charged
  to the physical press. Across 30 consecutive candidate self-test runs: ten seconds of PCM
  conversion took **0.26–0.35 ms**, ten seconds of Realtime packet construction **0.19–0.26 ms**, and
  a 500-term dictionary **3.48–4.63 ms**.
- **Final verification/deployment:** warning-free optimized compile; `git diff --check`; all
  SiriRemoteCore tests **133/133**; native Voice self-test **24/24 checks**, passed 30× as a raw binary
  and another 30× from the frozen candidate; credential/cache checks and the real OpenAI route pass.
  An independent sub-agent reviewed latency and concurrency twice after fixes and found no remaining
  P0/P1 issue. Stable-signed build `1.0.0-local.2` is installed only at
  `/Applications/HyperVibe.app`; deep strict signing and its unchanged Designated Requirement pass,
  helper CDHash is unchanged, exactly one UI process runs from that bundle, the existing Host process
  was not restarted, and the final runtime log contains no permission denial. Nothing was committed
  or pushed.

### ⚡ LATEST — 2026-08-27: Apple outreach package (uncommitted; not sent)

- A complete, public/non-confidential outreach kit now lives in `docs/apple-outreach/`: primary
  Accessibility Feedback email, short follow-up, editable one-page brief, two separately fileable
  Feedback Assistant enhancement reports, a 60-second animation-only demo script, and a public-claim
  audit. No email or Feedback report has been submitted.
- `output/pdf/HyperVibe-Apple-Overview.pdf` is the rendered one-page attachment. It passed visual
  review plus PDF bounds, text, link, form, JavaScript, and encryption checks.
- `website/apple/index.html` is an English Apple-review page that uses the current native App
  captures and the shared non-scroll-driven site runtime. It covers the voice-only workflow gap,
  pointer/ring/drag, all six gesture intents, App × Layer, visible state, voice, independent curves,
  agent-editable JSONC, operating reliability, and two precise macOS API requests. The local and
  Tailnet preview listeners on port 8765 serve it successfully; it still needs a public HTTPS URL
  before submission.
- Outreach language acknowledges Apple's existing Siri Remote Game Controller model for Apple TV
  and scopes the request to the complete paired third-generation Remote input surface on macOS plus
  a permissioned audio route. It avoids hardware-material, affiliation, clinical, App Store
  impossibility, and supported-microphone claims.
- Static website integrity, JavaScript syntax, all local HTTP resources, H.264 video metadata, and
  `git diff --check` pass. SiriRemoteCore passes **130/130** tests. A connected browser instance was
  unavailable for a fresh desktop/mobile visual pass, so signed-out browser QA remains on the final
  send checklist.
- A buildable, public-framework-only reproduction package lives at
  `docs/apple-outreach/samples/PublicAPIProbe`: `InputProbe` timestamps Game Controller elements and
  `AudioInputProbe` enumerates CoreAudio inputs. It contains no private HyperVibe implementation.
- Before sending: replace `PUBLIC_DEMO_URL`, file the two Feedback Assistant reports, insert their
  IDs, reconfirm the recorded macOS/Xcode/SDK versions, open every link signed out, then attach only
  the PDF to the email and the matching probe source/output to each Feedback report.
  Keep Tailnet URLs, raw packet data, identifiers, credentials, and private diagnostics out of the
  email. Nothing in this outreach package has been committed or pushed.

### ⚡ LATEST — 2026-08-27: Browser Layer 1 Delete + staged Back menu (uncommitted; live)

- Chrome and Safari both use the shared `browser` mode, so the Back-button behavior is consistent
  across browsers rather than living in an app-specific derived mode.
- In Browser's user-facing Layer 1 (`BASE`), Back-button tap is Delete. Its deliberate tap-then-hold
  ladder is: **Back at 0.5s**, **Close Window at 1.0s**, **Quit App at 1.7s**. This inserts a full
  0.5-second Back selection window and shifts the two existing destructive stages without making
  either easier to hit accidentally.
- Source of truth updated in `examples/config.author.jsonc`; the live machine-managed
  `~/.config/siriremote/config.jsonc` was updated atomically without changing any other saved GUI
  settings. `ExampleConfigTests.testAuthorBrowserBackMenuStartsWithDeleteThenBack` locks both browser
  profiles, actions, and thresholds against regression.
- Verification: all **130** SiriRemoteCore tests pass. No App rebuild/re-sign occurred; the existing
  `/Applications/HyperVibe.app` still validates as `siriRemote Local Signing`, and its sole UI process
  is PID **29737** at `/Applications/HyperVibe.app/Contents/MacOS/HyperVibe`. Its watcher reopened the
  replaced live config file, so the change is active. Nothing was committed or pushed.

### ⚡ LATEST — 2026-08-25: native automatic updates (uncommitted; locally deployed)

- Sparkle **2.9.4** is checksum-pinned by `app/prepare_sparkle.sh`, linked by the direct `swiftc`
  build, embedded with symlinks intact, and signed deepest-helper-first. The outer local App still
  has **no hardened runtime** (MultitouchSupport requirement); Sparkle's XPC/update helpers retain
  hardened runtime. Its full license ships as `Sparkle-LICENSE.txt`.
- Default behavior: daily background checks plus automatic verified download. Manual **Check for
  Updates…** exists in both menu bar and Settings. JSON remains the only preference source:
  `automaticUpdateChecksEnabled` and `automaticallyDownloadUpdatesEnabled` both default true and
  hot-reload/persist with the rest of `settings`.
- Update payload is the existing Full Setup `.pkg`, not app-only ZIP, so app, virtual mic, router
  and capture daemon remain one version. Package extraction requires Sparkle Ed25519 verification;
  installing system components still needs the normal macOS administrator authorization.
- Scheduled updates use Sparkle gentle reminders: no surprise focus steal. When an update waits,
  the menu icon gains a small dot and menu/Settings show its version; clicking brings Sparkle's
  standard UI forward. A `-local.N` development build never schedules production-feed checks but
  still supports manual checks.
- Release plumbing: monotonic build mapping in `dist/version.sh`; `build-release.sh` embeds the full
  prerelease version, audits Sparkle/framework/license/Info keys, then `update-appcast.sh` signs the
  package and updates/signs repository-root `appcast.xml`. The private Ed25519 key exists only in the
  login Keychain; public key is `soFR…c/Hk=` in Info.plist. Never export or commit the private key.
- Verification completed: app compiles warning-free; all **129** SiriRemoteCore tests pass; stable
  and explicit ad-hoc packaging paths both pass deep signature validation; shortcut-recorder
  headless test passes. Current live build is `/Applications/HyperVibe.app`, local build **10**, one
  process at last check, signed with the unchanged DR leaf
  `80f746bd1de5a7ceb835a200ce4e43705f01aee6` (no new TCC grants requested).
- Important publication state: `appcast.xml` is new and **not on GitHub main yet**, so manual update
  checks cannot work publicly until these reviewed changes are committed/pushed. Do not push merely
  to silence that 404; wait for explicit user approval. The current local build suppresses scheduled
  production checks, so it remains quiet meanwhile.

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

Display-only keys on any binding, used across Layout and the HUDs. Resolution order in
`ActionVisual`: measured variable volume/brightness symbol → real installed app icon for an action
that OPENS an app (`launch`, `shell` of the form `open -a "X"`) → binding JSON `icon` → real app icon
for an action AIMED at an app (`applescript` containing `tell application "X"`) → built-in action
symbol. Thus nearly every static icon is authored beside its JSON action, while the two cases that
must remain truthful—dynamic controls and launched Apps—cannot be accidentally made static.

Layer definitions accept their own `icon`. `settings.icons` owns non-binding interface symbols:
`layer.default`, `remote.connected`, `remote.disconnected`, all six native Voice result phases, and
`fallback`. Unknown symbols fall back safely. Both maps round-trip through `ConfigWriter`, hot-reload
into `LayerHUD`/`StatusWidget`, and remain intact after GUI settings saves.

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

## macOS tuning UI and Layer-1 desktop mapping (2026-08-10)

- The Tuning window is now a wide macOS workspace (`1040pt` preferred width): pointer and circular
  acceleration curves are always visible side by side at the top, with a draggable two-column split
  below. Both curves have three direct-manipulation points (slow endpoint, bend, fast endpoint).
- Pointer and circular-scroll acceleration are separate curves. `accelerationCurvesLinked` links
  only their dimensionless `accelCurve` bend; base speed, gain endpoints, thresholds, and physical
  units remain independent. The pointer runtime now applies the same `smoothstep^accelCurve` shape
  already used by circular scroll. Old configs decode to pointer curve `1.0` and unlocked.
- Desktop switching moved from ring-left/right **double press** to `L1.ring.left/right` **single
  press**. All base and L1 left/right double variants were removed, so common base-layer tab,
  track, or arrow actions no longer wait for `doubleTapWindow`.
- `browser` and `terminal` no longer override `L1.ring.left/right`; the global Layer-1 Space action
  therefore works consistently in every app. Their unlayered left/right bindings remain unchanged.
- The live config, `examples/config.author.jsonc`, `examples/config.jsonc`, and the README layer
  example must stay aligned with this resolution. Reintroducing any base `ring.left.double` or an
  app-specific L1 left/right override will restore latency or shadow desktop switching.

## Ordered layer cycle (2026-08-10)

- `settings.layers` is now the single ordered source of truth for layer identity, HUD name, colour,
  and cycling. It accepts 1–10 entries, must begin with `BASE`, and every later id names a mode.
  Users write exactly as many layers as they want; `{ "action": "layerCycle" }` advances through
  that array and wraps from its final entry to BASE.
- TV owns one inherited `button.tv → layerCycle` binding. L1/L2 no longer repeat the TV tap or hold
  mappings, so adding, removing, or reordering a layer requires no changes inside the mode blocks.
- The old `settings.layerHUD` dictionary remains decode-compatible. Its unordered keys migrate in
  deterministic BASE/L-number/custom-id order, and ConfigWriter emits only the new array schema.
- Layout's Add → Layer path now creates both the backing mode and its ordered layer entry, with
  separate internal id, display name, and colour fields. It refuses an 11th layer; removing a layer
  mode also removes its definition so UI saves cannot produce a config the loader rejects.
- New L2 copies the current app's BASE bindings through normal layer fall-through, but owns all four
  `ring.up/down/left/right` families as immediate plain arrow keystrokes. This also prevents BASE
  direction hold/double variants from leaking into L2.
- `button.tv.hold → appWheel` remains in BASE and falls through every layer that does not deliberately
  claim the TV button family.
- The pre-change live config backup is `/tmp/hypervibe-config-before-layer3.jsonc`.
- The pre-array live config backup is `/tmp/hypervibe-config-before-ordered-layers.jsonc`. A final
  canonical diff confirmed no tuning, app-profile, or non-TV binding changed during migration.
- Final verification: SiriRemoteCore 111/111 tests passed; both shipped JSONC examples parse; the
  complete macOS app builds and carries the stable `siriRemote Local Signing` identity. The normal
  standalone process was restarted from `app/HyperVibe.app`; `HyperVibe Host` was left untouched.

## Layer HUD colour and motion (2026-08-10)

- Layer state is no longer tied to `controlAccentColor` (usually blue). The fixed visual identity is
  BASE = system green, L1 = system blue, L2 = system purple; future numbered layers continue through
  orange, pink, teal, and indigo. Both the SF Symbol and a restrained card-gradient wash carry the
  colour, so the state remains distinguishable at a glance.
- The HUD never exposes internal ids when a configured `name` exists. Names are arbitrary; an empty
  name falls back to `Layer n` using the entry's array position, so custom ids still read naturally.
- Names and colours live directly on each `settings.layers` entry as `{ "id", "name", "color" }`.
  Named adaptive system colours plus `#RRGGBB` and `#RRGGBBAA` are accepted; missing/invalid values
  fall back to the built-in ordinal/palette. The typed array round-trips through ConfigWriter, and
  order/name/colour update together on config hot reload.
- A visible layer change is an in-place 0.30 s push: old icon/type travel left and the destination
  enters from the right. The card compresses and settles over 0.34 s while its gradient and border
  interpolate continuously. First appearance remains a separate 0.38 s rise-and-settle animation.
- Repeated notifications with the same presentation key do not replay the transition. Rapid layer
  taps replace the named Core Animation keys and begin colour interpolation from the presentation
  layer, avoiding queued or discontinuous animations.
- Multi-display mirroring is unchanged: every physical screen owns a synchronized Surface and all
  surfaces receive the same transition. New windows begin transparent, which also fixes a newly
  attached display popping in while another HUD surface is already visible.
- `--test-layer-hud` now walks BASE → L1 → L2 → BASE at 0.65 s intervals so an in-place transition is
  exercised rather than only two isolated fade-ins. Visual QC was recorded at 4096×2304/120 Hz via
  `/tmp/hypervibe-hud-cycle.mov`; 30 fps contact-sheet inspection confirmed the push, tint morph,
  scale settle, and final fade on real rendered frames.

## Optional persistent status widget (2026-08-10)

- `settings.statusWidgetEnabled` (default `false`) and the Tuning-tab **On-screen Status** toggle
  control a separate compact status surface. The generic example stays opt-in; the maintainer
  example enables it. Old configs decode to `false`, so upgrading cannot unexpectedly add chrome.
- At rest the card shows the effective layer's configured name and colour. `Controller` publishes a
  typed `HandledAction` only after a binding resolves; the card therefore shows the exact action and
  presentation that fires through app/layer inheritance, never an unbound raw button report. App
  activation comes from `AppWatcher` and uses the real installed app icon.
- Launch actions are presented immediately, before app activation completes. The following
  AppWatcher confirmation is matched by normalized app name and updates without bouncing the same
  icon twice. Media/AppleScript actions deliberately prefer action-specific symbols (next,
  previous, play/pause) over the targeted app icon, so “open Music” and “next track” are visually
  distinct.
- Display time is input-aware: ordinary actions 0.66 s, double 0.80 s, triple 0.92 s, hold stages
  1.05/1.20/1.35 s, app activation 0.90 s. Each new discrete gesture gets its own spring; a continuous
  stream of identical repeat events inside 220 ms shares one pulse and only extends its dwell. A
  generation token prevents an expired timer from overwriting a newer action or layer.
- Push-to-talk and explicit `repeatKey` bindings bypass `Controller.handle` for matched raw edges and
  genuine key-down repeat. Those paths explicitly report the captured/resolved binding through the
  same callback: PTT only after its 0.2 s opener really fires (never on a cancelled quick tap), and
  repeatKey once on press rather than once per timer tick.
- The non-activating `NSPanel` joins every Space and full-screen Space without stealing focus. Its
  entire surface is draggable. `UserDefaults` stores the `CGDirectDisplayID` plus X/Y normalized to
  that screen's visible frame; resolution changes reproject it, off-screen drags are clamped after
  mouse-up, and disconnecting the saved monitor relocates and rehomes it on an available display.
- `--test-status-widget` exercises Layer → Music icon → Next Track → Layer → Voice Input without
  touching remote IO, rcd, Accessibility, or the normal running app. Core verification after the
  direct-action pipeline addition: 113/113 tests passed.

## Relative brightness and semantic status motion (2026-08-23)

- Layer 3 is config mode `L2`. Its volume-up/down buttons now use the new relative
  `{ "action": "brightnessStep", "to": "up|down" }` action, so each press changes display
  brightness without pretending a relative key is an absolute brightness value. The action is
  represented in `Action`, ConfigLoader/Writer, the GUI binding editor, localization, visual
  feedback, `MacActionExecutor`, and hold-repeat eligibility. Both maintained example configs map
  the two Layer-3 buttons to it.
- The persistent widget now has one deterministic motion grammar rather than a generic/random icon
  replacement. All compact transitions stay inside 200–280 ms, use transform/opacity/path animation
  on Core Animation, remain interruptible by the next event, and leave the card frame plus Layer
  aura fixed. `accessibilityDisplayShouldReduceMotion` still selects the restrained fallback.
- Layer switching is an in-place 240 ms three-sheet rebuild: the stack separates, its outer sheets
  exchange order on opposite shallow arcs, and all three rejoin as the destination layer. App
  recognition uses a 240 ms circular aperture/focus arrival. Direct single/double/triple gestures
  use one/two/three 200 ms impulse rings. A plain Back-button action has a dedicated 220 ms leftward
  causal handoff; the later idle return is a quieter 200 ms opposing depth settle.
- Hold stages use a 240 ms depth relay while the existing whole-card water progress remains the
  source of timing truth. Voice mode, its real audio waveform, pitch colour and hold/release path
  were deliberately left unchanged because that treatment is already accepted.
- Connection is a 260–280 ms internal focus/ripple entrance; disconnect is a separate 220–240 ms
  inward resolve and panel exit, not a reversed celebration. The card never scales, so the Layer
  border stays registered. Title/subtitle changes use exact Retina snapshots on the same compositor
  timeline and exchange at a 56° horizontal-axis turn, avoiding both timer jank and double-exposed
  text.
- Permission-free visual-QC states now include `layer-cycle`, `semantic-cycle`,
  `connection-cycle`, and `return-cycle`. They never start HID discovery or emit system input.
  Window-only ScreenCaptureKit recordings (244×112 only) were inspected frame-by-frame from `/tmp`;
  no desktop content or capture helper was added to the repository.
- Final verification on 2026-08-23: the full macOS executable builds and SiriRemoteCore passes
  **127/127** tests. The stable `siriRemote Local Signing` identity is usable, but on this macOS
  `security find-identity -p codesigning` misleadingly reports `0 valid identities` for that
  self-signed certificate. Do not use that command as the gate: unlock the dedicated keychain,
  confirm the named certificate exists, let `codesign` prove private-key access, then require
  `codesign --verify --deep --strict`. Never silently fall back to ad-hoc signing.
- The verified build was installed and restarted at `/Applications/HyperVibe.app`. Its designated
  requirement is `identifier "com.hypervibe.app"` plus certificate SHA-1
  `80f746bd1de5a7ceb835a200ce4e43705f01aee6`; Authority is `siriRemote Local Signing`. Exactly one
  UI process was running afterward at the required path (PID 11739 at final verification), and `HyperVibe Host` PID 906
  was left untouched. The preceding installed bundle is recoverable from
  `/tmp/HyperVibe-installed-before-20260823-0255.app` for this machine session.

## Native SF Symbols and semantic action colour (2026-08-23)

- `app/ActionSymbolStyle.swift` is now the single semantic source for every dynamic action symbol.
  `ActionVisual` carries SF Symbol provenance, semantic system tint and motion cue together; the
  persistent status widget, large hold-progress HUD and transient Layer/connection HUD consume that
  same payload. A custom JSON `icon` may change the drawing but cannot accidentally erase the
  action's severity or physical behaviour.
- The action audit covers every `Action` case and the shortcuts used by the live/default configs:
  volume, mute, playback, next/previous, brightness, four directions, Back/delete, copy/paste/cut,
  Spotlight, fullscreen/minimise, pointer move/click/context click/scroll, launch/App Wheel, sleep,
  voice, Layer/mode, close window and AppleScript quit. Repeated keystrokes retain the underlying
  key's cue; only an otherwise generic command inherits the physical Back key's return cue.
- Colour is semantic and adaptive, never a hard-coded RGB substitute: character deletion and
  navigation are system blue; Close Window, Cmd-W/Cmd-Q and quit scripts are system red; mute,
  minimise and cut are system orange; media is system pink; pointer operations are system teal;
  confirmation is system green; search/launch/sleep use indigo or purple. Shape, label and motion
  remain present so colour is never the sole carrier of meaning.
- All SF Symbols are configured with hierarchical rendering, preserving Apple's authored primary,
  secondary and tertiary layers. On macOS 15+ symbol-to-symbol changes use Magic Replace with a
  by-layer Replace fallback; macOS 14 uses by-layer Replace directly; macOS 13 keeps the existing
  Core Animation fallback. Layer reconstruction uses Draw On by layer on macOS 26 and a cleared
  by-layer Appear state on older supported Symbols runtimes. Draw On is also guarded with
  `#if compiler(>=6.2)`: runtime `#available` alone is insufficient because the Xcode 16/macOS 15 SDK
  used by GitHub CI cannot parse a macOS 26 symbol name. Volume uses variable colour; directional,
  media, brightness, destructive, sleep, search, copy/paste/cut and pointer families each have a
  deterministic native effect inside the existing 0.2–0.3 s interaction envelope.
- The web-only `morphicons` library was deliberately not embedded: it morphs supplied SVG/path data,
  whereas native AppKit receives `NSSymbolImageRep` and Apple does not expose arbitrary SF Symbol SVG
  geometry at runtime. The native Symbols framework therefore gives better topology, accessibility,
  OS-version fallback and Apple-authored layer motion without shipping a parallel JS renderer.
- The large water HUD no longer forces every template glyph to white. Delete stays blue, Close/Quit
  are red, Cancel is teal, and real app artwork retains its native colour. Stage changes use native
  topology-aware symbol replacement; non-symbol app artwork keeps a restrained scale fallback.
- In the transient Layer HUD, the icon was separated from the rolling text container. The card stays
  fixed, titles roll vertically, and the three stack layers rebuild in place while the configured
  layer colour interpolates. Connected is green; disconnected is system orange (attention, not
  destructive red) and replaces the filled remote with its outline form.
- Window-only ScreenCaptureKit QA (no desktop, other app, cursor or audio capture) was inspected at
  actual transition frames. Key artifacts in `/tmp` are
  `hypervibe-symbol-audit-full.mov`, `hypervibe-back-hold-shared-semantics-full.mov`, and
  `hypervibe-layer-symbol-native-full.mov`. The full action contact sheet confirmed all semantic
  families; the Layer transition showed the icon's three authored pieces entering in order while
  text rolled independently. The large Back ladder confirmed red Close/Quit over the complete water
  fill and neutral Cancel recovery.
- Verification: full app build passes, `git diff --check` is clean, the AppKit shortcut recorder
  self-test passes, and SiriRemoteCore passes **127/127** tests. The final candidate was packaged at
  `/tmp/HyperVibe-candidate-20260823-140448.app`, passed deep/strict code-sign verification and was
  installed at `/Applications/HyperVibe.app` with identifier `com.hypervibe.app`, Authority
  `siriRemote Local Signing`, and the unchanged leaf SHA-1
  `80f746bd1de5a7ceb835a200ce4e43705f01aee6`.
- Deployment verification found exactly one installed UI process at
  `/Applications/HyperVibe.app/Contents/MacOS/HyperVibe` (PID 45898) and left `HyperVibe Host` PID 906
  untouched. Startup logs confirmed existing Input Monitoring access, a live media-key event tap,
  successful HID manager open and the configured Siri Remote interfaces being seized. The preceding
  installed bundle remains recoverable at
  `/tmp/HyperVibe-installed-before-20260823-140448.backup`; its non-`.app` suffix is intentional so
  LaunchServices cannot prefer the backup over the installed app when both share the same bundle ID.
- When verifying a restart, filter `ps` before returning its output. A full process table may be
  truncated before HyperVibe's PID appears; that briefly made the still-running old UI look absent
  during this deployment. Checking the exact PID/path exposed it, after which only that UI PID was
  terminated and the installed candidate was genuinely launched.

## Stateful volume/brightness symbols and interruption correction (2026-08-23)

- Volume-up/down are now two inputs into one measured output state, not two differently-sized
  icons. Both render Apple's variable `speaker.wave.3.fill`; CoreAudio's default output device,
  mute property and virtual-main/master/channel volume determine the visible waves. Mute resolves
  to the related `speaker.slash.fill` state. A configured static icon is deliberately ignored for
  this dynamic family so it can never contradict measured system state; custom labels still work.
- Brightness-up/down likewise share one state symbol. `sun.max.fill` must not be used for this: a
  raster probe confirmed that its 5% and 95% `variableValue` output is pixel-identical. The shipped
  feedback uses Apple's real variable `sun.max.circle`, whose authored circular state advances with
  the live value returned by the existing built-in-first DisplayServices brightness reader.
- `Controller` announces the binding immediately before its executor posts the system key. The
  widget therefore presents immediately from the current measurement, then samples again after the
  media/brightness event has landed and changes only the variable-value image in place. Absolute
  brightness ramps receive two additional samples. The refresh never restarts the card transition,
  SF Symbol cue, or dwell grammar.
- A complete volume/brightness burst owns one stable face. Identical ticks only extend dwell; a
  direction or measured-value change redraws atomically. The input-free `interruption-cycle` test
  accepts deterministic state overrides, proving low→high→low waves and brightness progress without
  changing the test machine's controls.
- Equal-colour palette rendering replaces hierarchical opacity falloff, so the settled primary,
  secondary and tertiary layers remain equally readable. Magic Replace is now restricted to real
  topology families (same fill variant, speaker, sun, layer stack and Apple TV Remote). Unrelated
  symbols keep the app's compositor transition instead of briefly merging into a malformed glyph.
- Verification before deployment: the full AppKit executable builds; `git diff --check` is clean;
  SiriRemoteCore passes **127/127** tests; and window-only recording
  `/tmp/hypervibe-variable-controls-v2.mov` was inspected frame by frame. It confirms both control
  families change with value while rapid ticks do not replay their entrance animation.
- The stable-signed candidate `/tmp/HyperVibe-candidate-20260823-1506.app` passed deep/strict
  verification before and after staging, then replaced the installed UI at
  `/Applications/HyperVibe.app`. Identifier remains `com.hypervibe.app`, Authority is
  `siriRemote Local Signing`, and leaf SHA-1 remains
  `80f746bd1de5a7ceb835a200ce4e43705f01aee6`. Final process audit found exactly one UI process
  (PID 68546) and preserved Host PID 906. `/tmp/hypervibe.log` confirms Input Monitoring granted,
  IOHIDManager open success, the media event tap installed, and all five remote interfaces seized.
  The prior installed bundle is recoverable at
  `/tmp/HyperVibe-installed-before-20260823-1506.backup`.

## App Wheel relay and stateful Mute replacement (2026-08-23)

- The App Wheel no longer enters through the generic whole-icon action impulse. Both a direct
  `.appWheel` action and the production TV-hold stage select `IconMotion.appWheelWave`. The
  destination `circle.grid.3x3.fill` snapshot is divided into its nine real Retina-rendered dots;
  a unique diagonal relay reveals them one by one, then crossfades to the exact complete SF Symbol
  during the normal proxy handoff. The card never changes size and the complete track remains
  inside 280 ms.
- System-output Mute AppleScript (`set volume output muted ...`) now shares the same CoreAudio state
  reader as media-key mute. App-specific scripts such as Music's private `set mute` deliberately do
  not use CoreAudio, because system output state cannot truthfully represent app-local mute.
- The compact widget names the measured result: muted shows `Mute` plus
  `speaker.slash.fill`; unmuted shows `Unmute` plus `speaker.wave.3.fill`. Conventional configured
  Mute/Unmute labels opt into the live wording, while a genuinely custom label remains untouched.
  Chinese `Unmute` is localised as `未静音`.
- The post-action sample no longer atomically swaps mute artwork. It applies Apple's native Magic
  Replace at speed 2.8 with no competing variable-colour cue, so the speaker body remains continuous
  while the slash draws on/off and the wave layers return. If the initial Layer → Mute transition is
  still landing, the measured edge waits for its exact proxy handoff rather than playing invisibly
  underneath it. A generation guard prevents a stale delayed sample from winning over a rapid
  second press.
- Permission-free visual states `app-wheel-wave` and `mute-state-cycle` were added. Window-only
  recordings `/tmp/hypervibe-app-wheel-wave.mov` and
  `/tmp/hypervibe-mute-magic-replace.mov` were inspected frame by frame: all nine dot relay stages
  are visible without a final position jump, and native slash entry/removal is visible in distinct
  frames. The Mute preview uses deterministic overrides and never changes real system audio.
- Verification: the app builds, `git diff --check` is clean, and SiriRemoteCore passes **127/127**
  tests. The candidate passed deep/strict signature checks before and after staging and was installed
  at `/Applications/HyperVibe.app`. Identifier remains `com.hypervibe.app`, Authority remains
  `siriRemote Local Signing`, and the certificate leaf SHA-1 is unchanged at
  `80f746bd1de5a7ceb835a200ce4e43705f01aee6`. Final audit found exactly one installed UI process
  (PID 93278) and preserved `HyperVibe Host` PID 906. Startup logs confirm Input Monitoring granted,
  IOHIDManager open success, media event tap active, and all five remote interfaces seized. The
  previous installed UI bundle is recoverable at
  `/tmp/HyperVibe-installed-before-20260823-1542.backup`.

## Single-clock hold stages and one-edge Mute transactions (2026-08-23)

- Root cause of the reported Back hold lag was two nominally related but mechanically independent
  timelines. The compact widget's water sampled `CACurrentMediaTime()` every frame, while Close,
  Quit and Cancel faces were each queued with their own `DispatchQueue.main.asyncAfter`. Main-queue
  pressure could therefore advance the water and leave one or more face callbacks waiting behind it.
- All per-threshold face work items have been removed. `HoldTiming.reachedStageCount` is now the pure
  shared resolver used by input selection, the compact whole-card water surface and the large water
  HUD. A compact-widget display tick takes one `elapsed` sample, resolves one current stage, starts
  its water clear/fill and installs that exact stage face in the same main-loop/compositor turn.
  There is no second timer capable of drifting away.
- A late frame never replays missed faces. For example, a jump from 0.40 s directly to 1.35 s lands
  immediately on Quit (stage 2), with no delayed Close animation in front of it. Ordinary adjacent
  boundaries retain the authored 260 ms hold transition, but its destination begins visibly on the
  boundary frame rather than remaining hidden for the first 42% of the effect.
- The first compact visual callback is also a real timeline sample. If setup is late or a configured
  threshold is earlier than the normal 180 ms visual lead-in, it renders the action that release
  would select at that instant instead of drawing a cosmetic stage-zero frame first. Threshold arrays
  are cached at hold start so the 60/120 Hz paths allocate nothing per frame.
- The separate Mute double-presentation bug was a pre-action/post-action ordering error, not duplicate
  HID execution. `Controller` reports the binding before its executor toggles CoreAudio, so the old
  implementation first showed the pre-toggle state and then animated the measured result. A system
  Mute press now predicts and presents its post-toggle state as one transaction; delayed CoreAudio
  sampling only confirms it and is normally a no-op. The actual output scalar is preserved while
  muted, so predicted Unmute artwork retains the correct speaker-wave level. A failed action can
  still correct itself from the confirmation sample.
- Verification: the full app builds; SiriRemoteCore passes **129/129** tests, including exact-boundary
  and skipped-frame regressions; and the window-only recording
  `/tmp/hypervibe-back-hold-sync.mov` was inspected at 30 fps around both production thresholds.
  Close and Quit icon motion begins on the same recorded frame as the water enters its stage clear;
  no desktop content, input device or real action was used by that test.
- The stable-signed candidate `/tmp/HyperVibe-candidate-hold-sync-20260823.app` passed deep/strict
  verification before and after staging. The installed app remains identifier `com.hypervibe.app`,
  Authority `siriRemote Local Signing`, and leaf SHA-1
  `80f746bd1de5a7ceb835a200ce4e43705f01aee6`. Final audit found exactly one installed UI process
  (PID 8119), preserved `HyperVibe Host` PID 906, and confirmed Input Monitoring granted, the media
  event tap active, IOHIDManager open success and all five remote interfaces seized. The preceding
  installed bundle is recoverable at
  `/tmp/HyperVibe-installed-before-hold-sync-20260823.backup`.

## Static website rebuild and current-product capture set (2026-08-23)

- This supersedes the earlier pinned/scroll-scrub opening concept. The website is now a conventional
  vertical product page: no ScrollTrigger dependency, no pinned scene, no scrubbed progress, and no
  scroll event controlling product state. Scrolling only navigates the document. Pointer, ring,
  sticky-drag, capability and curve demonstrations run on independent looping timelines and pause
  off-screen through `IntersectionObserver`.
- The page was rebuilt as one coherent software story: complete one-hand input, the gap left by
  voice-only tools, Web-coding and standing-presentation scenarios, touch plus accelerated ring
  input, the full tap/double/triple/three-stage-hold grammar, App × Layer resolution, native visual
  feedback, remote voice features, independent acceleration curves, JSONC/GUI parity, Agent-friendly
  configuration, and operational reliability. Hardware materials are not marketed.
- All product media was refreshed from the installed 2026-08-23 build rather than reusing the old
  website mockups. Current stills are `current-layout.png`, `current-tuning.png` and the exact remote
  crop `current-remote.png`. Current native loops are `current-status-semantic.mp4`,
  `current-status-controls.mp4`, `current-status-layers.mp4`, `current-status-app-wheel.mp4`,
  `current-status-mute.mp4`, `current-status-voice.mp4`, `current-back-hud.mp4` and
  `current-layer-hud.mp4`. They were captured with the App's isolated visual-QA flags: no physical
  input, desktop capture, system-control mutation or audio capture was used.
- `website/index.html`, `website/styles.css` and `website/app.js` are now the complete site. The old
  split `opening.css` was removed. Real App captures carry the product visuals; the web layer adds
  only explanatory signal traces and acceleration diagrams. All native films are muted, autoplaying,
  inline loops; reduced-motion pauses them and leaves every chapter visible.
- Browser QA ran against the exact Tailscale URL at 1440×1000 and 390×844. It exercised pointer,
  ring and sticky-drag controls and inspected every desktop and phone chapter. The final document has
  no console errors, failed requests, bad responses, broken images or horizontal overflow; the phone
  document width is exactly 390 px. All nine video elements reached ready state 4. `app.js` passes
  `node --check`, `window.ScrollTrigger` is absent, and source inspection finds no scroll listener.
- Local and Tailnet preview listeners remain available on port 8765. The exact Tailnet address is
  deliberately kept out of the public repository. This website pass did not modify, rebuild, sign,
  restart or reconfigure the macOS App; it ships with `v0.2.0-beta.4`.

## Native Installer and live System Check (2026-08-24)

- Release packaging now emits a third binary asset,
  `HyperVibe-Full-Setup-VERSION-arm64.pkg`, alongside the app-only and legacy Full Setup ZIPs.
  The package uses Apple's Installer UI with bilingual welcome/readme/conclusion/license pages,
  stages a checksum-sealed payload, and runs the same privileged `do_install.sh` path as Setup.app.
  It installs HyperVibe, the HAL virtual microphone, router, on-demand capture daemon and the
  uninstaller with one administrator approval. Existing config is preserved; a public default is
  seeded only when the active user has no config. The root postinstall refuses config-directory or
  config-file symlinks and creates only the one default file as the console user; it never
  recursively changes ownership inside the user's home.
- The privileged install path verifies the nested app and uninstaller signatures before replacing
  anything, backs up both installed apps, the HAL driver, microphone support directory and
  LaunchDaemon, and restores the complete previous set on failure.
  It kills only the exact `HyperVibe` UI process, never `HyperVibe Host`, retains the 25-second
  coreaudiod watchdog, and logs native installs to `/var/log/hypervibe-install.log`.
- First-run permission handling is now one live **System Check**, not a chain of unexplained TCC
  prompts or dialogs that assume a settings page was completed. Accessibility and Input Monitoring
  are clearly required; Microphone, Automation, Siri Remote Mic components and Apple's separately
  distributed PacketLogger are feature-specific. Permission requests occur only from explicit
  buttons. Status refreshes live on app activation and a short timer, and a newly granted core
  permission reattaches its HID manager or media event tap without requiring an App restart.
- The same check is available from the menu bar, Settings and `--system-check`. The menu bar exposes
  persistent `Permissions: Ready` / `Action needed` health. Both the native package postinstall and
  legacy Setup.app explicitly launch this screen, so all installation entry points share the same
  recovery flow. The window remains closable, but users cannot mark setup complete while either
  core permission is absent.
- A full dirty-worktree preview with bundle build 5 passed 129/129 core tests, app compilation,
  payload checksums, deep/strict nested signature verification, Installer XML/script validation,
  app/package binary hash equality, arm64/macOS 13 checks, public-config isolation and license
  checks. The locally installed test App was built separately with the unchanged
  `siriRemote Local Signing` leaf SHA-1
  `80F746BD1DE5A7CEB835A200CE4E43705F01AEE6`; exactly one UI process runs from
  `/Applications/HyperVibe.app/Contents/MacOS/HyperVibe` and existing TCC grants were preserved.
- There is currently no `Developer ID Installer` identity in the keychain. App code-signing and
  Installer signing are distinct certificate classes; never misuse the local App signer or claim an
  unsigned package is notarized. `dist/package.sh` signs with
  `HYPERVIBE_INSTALLER_SIGN_IDENTITY` when a real Installer identity is supplied, otherwise emits
  an explicitly audited unsigned beta package. Do not install that public/ad-hoc payload over the
  stable-signed local test App.

## Floating presentation remote controls (2026-08-27)

- The passive remote-only presentation panel is controlled by one portable setting:
  `settings.demoRemoteEnabled` (default `false`). The Settings **On-screen Status** toggle,
  menu-bar **Demo Remote** item, JSONC hot reload and the panel's own Close command all converge on
  the same `SettingsModel` value; GUI changes therefore persist back to `config.jsonc` instead of
  creating a second preference source.
- Right-clicking anywhere on the remote opens a non-activating native context menu. **Size** offers
  Small (110 pt), Medium (156 pt) and Large (234 pt), with the exact active preset checked; resizing
  animates around the current centre for 200 ms and clamps the result to the visible display.
  **Close Demo Remote** hides it immediately and disables it in JSON through the shared model.
- Free corner resizing remains available and preserves the authored aspect ratio. Window size,
  normalized position and display ID stay in `UserDefaults` because they are machine/display local;
  a missing display recovers the remote onto an available screen. They are intentionally not part
  of portable JSON configuration.
- Verification for this pass: `git diff --check`, the full App build, and **130/130**
  SiriRemoteCore tests passed, including decode defaults, explicit JSON override and writer
  round-trip coverage for `demoRemoteEnabled`.

## Native Voice pipeline presentation and independent capsule (2026-08-28)

- Final-mode Voice presentation now has one shared semantic model,
  `VoicePipelineVisualStage`, for Listening, Transcribing, Polishing, Inserting, Inserted, Copied
  and Error. The persistent status widget and the new temporary capsule therefore cannot drift into
  different labels, icons, colours or stage ordering. Streaming remains deliberately different: a
  successful release returns directly to the current Layer instead of pretending to run the Final
  Transcribing/Inserting/Inserted sequence.
- Layer 2's status-widget pipeline is now a continuous visual hand-off. The last real waveform
  compresses into the Transcribing pulse; stage colours and acoustic contour filaments travel into
  the next symbol; Apple's by-layer symbol replacement carries the icon; and title/detail lines flip
  around their centre axes. The card keeps the exact same outer geometry throughout—no whole-window
  scale, black shadow, layout jump or post-animation one-pixel text snap. Native key-up waits for the
  synchronous coordinator phase, so Voice transforms directly into Transcribing rather than flashing
  the Layer face in between.
- `VoicePipelineHUD.swift` adds the requested independent Typeless-style temporary capsule. It is a
  non-activating all-Spaces panel with a fixed 312×84 pt window and 300×60 pt visual card, a 21-bar
  real acoustic waveform, pitch/brightness colour, a stage rail, open progress arc and semantic
  terminal states. It can be dragged, stores a display-relative position, and recovers onto an
  available screen when its previous monitor disappears. It is independent of the always-on status
  widget and is controlled by `settings.dictation.pipelineOverlayEnabled` (default `true`) in JSONC
  and the Voice settings page.
- Animation teardown is interruption-safe. Temporary text layers are committed to their hidden model
  endpoint before their Core Animation proxy is removed, stage generations reject stale completions,
  key-up retains the last waveform until the coordinator supplies the real next phase, and a new hold
  can interrupt either a terminal card or Streaming's release collapse without making the panel blink,
  resize or resurrect old text.
- Visual QA used only installed-App deterministic preview modes; it opened no microphone, HID device,
  network session or input target. Normal capsule transitions were inspected in
  `/private/tmp/hypervibe-voice-pipeline-build9-normal.mov`, rapid 100 ms stage changes and release
  interruption in `/private/tmp/hypervibe-voice-pipeline-build10-interrupt.mov`, and the persistent
  Layer 2 pipeline in `/private/tmp/hypervibe-status-widget-build10-pipeline-final.mov`. Retina screen
  coordinates were measured before cropping; frame sheets confirmed one readable text state at a
  time, fixed geometry, visible filled-symbol details and no stale-frame reappearance.
- Final verification: SiriRemoteCore passes **134/134** tests and the exact packaged binary passes
  **46/46** Voice self-checks (`dictionary=3.77 ms`, 10-second PCM conversion `0.32 ms`, packetisation
  `0.19 ms`). Local build `1.0.0-local.10` is installed at `/Applications/HyperVibe.app`; deep/strict
  verification succeeds with identifier `com.hypervibe.app`, `siriRemote Local Signing` certificate
  leaf SHA-1 `80f746bd1de5a7ceb835a200ce4e43705f01aee6`, and unchanged credential-broker CDHash
  `13d5c95754534f4fcc26799385d9f48b8ac8c544`. The preceding verified App and config are recoverable
  from `/private/tmp/hypervibe-voice-pipeline-build6-backup.XwlNYg/`. Preview films and backups are
  outside the repository; this pass has not been committed or pushed. Final restart left exactly one
  UI process (PID 90784) at `/Applications/HyperVibe.app/Contents/MacOS/HyperVibe`, preserved
  `HyperVibe Host` PID 906, and logged Input Monitoring granted, IOHIDManager open success, the media
  event tap active and all five remote interfaces seized.

## Cloudflare website — low-latency Voice story (2026-08-28)

- The product site now presents native Voice as a concise speed story rather than a technical
  pipeline explanation: **press for immediate response, speak for live text, release for rapid
  delivery**. It distinguishes Streaming from polished Final output, notes automatic remote/Mac
  microphone selection, and keeps the Layer-specific routing explanation brief.
- `website/media/current-voice-pipeline.mp4` is a real native-App capture, curated into a seamless
  5.37-second 60 fps loop covering Listening through Inserted. The website stage rail follows that
  loop through `setupVoicePipeline()` and pauses with the existing off-screen/reduced-motion policy.
- The public source mirror is the personal-site repository's `public/siriremote/` directory.
  Production is the **`wenqian-dev` Cloudflare Worker** serving `wenqian.dev`, not a standalone
  Pages project and not the Tailnet preview. Do not deploy `website/` as a Pages project or
  overwrite the personal-site root.
- Because `my-web` contained unrelated dirty work, this deployment reused the exact latest
  `.open-next` Worker build and changed only five assets under `/siriremote/`: HTML, CSS, JavaScript,
  the Voice film, and the Apple page. Deployment ran from an isolated `/private/tmp` staging tree
  containing no `.dev.vars` or `.env`; Cloudflare's existing production secrets and bindings were
  preserved. Production version is `cc702187-18f2-4cb6-b9d8-f93a7f3399a3`, message
  `hypervibe-voice-showcase`.
- Production回读 passed for the main personal site, `/siriremote/`, `/siriremote/apple/`, JS, CSS and
  MP4. The live HTML/JS/CSS/video are byte-for-byte identical to this repository's website files;
  the video SHA-256 is `26e23596d33af7562862a336388b88154dddfbda3c3c469b8a70065d18d84d39`.
  No connected in-app browser was available for a new visual desktop/mobile pass, so do not claim
  browser visual QA for this deployment. The macOS App was not rebuilt, installed, restarted or
  otherwise touched.

## Cloudflare website — global Voice mode switcher (2026-08-28)

- The Voice chapter now matches the App's global routing model instead of presenting Voice as a
  Layer-owned feature. **Hold Mute + tap Side** silently cycles External, Final and Live from every
  Layer; the page explicitly states that External returns Side to its configured action and never
  shows the Voice capsule.
- The new three-state demonstration uses the App's blue/purple/orange mode identities and a single
  authored GSAP loop. External truthfully clears the stage, Final replays the real native pipeline,
  and Live presents immediate streaming. Manual selection pauses the loop long enough to inspect a
  mode, then resumes. Icon turns and copy transitions stay within 220–240 ms; reduced-motion and
  GSAP-unavailable fallbacks remain functional.
- The configuration example now exposes `settings.dictation.activeMode` as `"final"` and describes
  Voice, icons and HUD visibility as JSON-controllable. Source files are `website/index.html`,
  `website/styles.css` and `website/app.js`; their exact copies were synced to
  the personal-site repository's `public/siriremote/` directory.
- Deployment again reused the isolated, previously verified OpenNext Worker tree so none of the
  unrelated dirty `my-web` work could ship. Wrangler `--strict` dry-run passed with all production
  D1/KV/R2/Analytics bindings intact, then uploaded exactly the three changed `/siriremote/` assets.
  Cloudflare production version is `37072d26-ffaf-4267-adad-fa1ba238081c`, message
  `hypervibe-global-voice-modes`.
- Production回读 proved the live HTML, CSS and JavaScript are byte-for-byte identical to the website
  sources (SHA-256 `73eeb2a633e4c6a72b47b0415ac93bdf1b7e1acb70dac9be38371328062426e8`,
  `3975bf6a1e1230686c8d691944250cacc8a7e622d236df11da10cd5fe433eacb`, and
  `feb55c193945865f0b7cd715c5073dcb88f6b872ee15c09c55202f49afb3a036`). JavaScript syntax and diff
  whitespace checks pass. No connected in-app browser was available, so this pass does not claim a
  fresh screenshot-based visual QA result. The macOS App was not rebuilt, installed or restarted.

## Cloudflare website — complete product story (2026-08-28)

- The product page is no longer a thin sequence of isolated feature highlights. Its HTML expanded
  from 429 to 674 lines and now carries one continuous software story: the voice-only control gap,
  four real workflows, touch/ring control, all 13 physical press points, the six-gesture grammar,
  App × Layer resolution, native visual feedback, global Voice, acceleration tuning, shared
  GUI/JSON/Agent configuration, long-running system behaviour, onboarding and updates.
- The new **13 × 6** atlas names every configurable press point and shows up to 78 gesture slots.
  The App × Layer chapter now animates all four resolver priorities instead of merely asserting that
  contextual mapping exists. The action vocabulary enumerates input/media, window/Space,
  launch/automation and state actions, followed by a concrete Agent → patch → validate → hot-reload
  path.
- Four authored workflow panels cover Agent coding, standing presentations, multi-display work and
  media/reading. Voice now documents source locking, pre-warming, Final cleanup, insertion/paste/copy
  fallback, secure-field refusal, last-result recovery, Keychain storage and the native latency
  telemetry. Installation now distinguishes App-only from Full Setup and explains System Check,
  pairing and signed Sparkle updates.
- All new interactive systems use existing GSAP core/timelines, 220–240 ms UI transitions and
  infinite authored loops. They pause outside the viewport through the existing observer, respect
  reduced motion and do not add ScrollTrigger, scroll listeners or whole-card scaling. Manual
  workflow/resolver selection pauses the automatic story long enough to inspect it, then resumes.
- Source, the personal-site `public/siriremote/` mirror and the isolated OpenNext deployment tree
  were synchronized byte-for-byte. Strict Wrangler dry-run preserved the existing Worker and all
  D1/KV/R2/Analytics bindings; production uploaded exactly HTML, CSS and JavaScript while reusing
  237 existing assets. Cloudflare version is `c98026fc-e7fe-4213-955b-e98718ba3ced`, message
  `hypervibe-complete-product-story`.
- Production回读 proved byte identity for HTML, CSS and JavaScript (SHA-256
  `7b6644be9aadb902428478957328decadd0d0e35d30a20a5d0a429877c073c88`,
  `2bee94da950b5f7fb5f62aaf395dbaf84f778dcef557a7a82cbd6ebb0271e2ab`, and
  `9b1a9529240baf07b47bbb5dd0c6ff90c9ada56356054da03a9239e33559712b`). JavaScript syntax,
  whitespace, duplicate-ID, anchor-target and local HTTP checks pass. Browser discovery again
  returned no available browser, so do not claim fresh screenshot-level desktop/mobile QA. The
  macOS App was not rebuilt, installed, restarted or otherwise touched.

## Cloudflare website — compact information density (2026-08-28)

- The full product story remains intact, but the page no longer treats every chapter like a
  full-screen keynote slide. Global section spacing is down from a maximum of 132 px to 84 px
  (about 36% less), with the tablet/mobile value reduced from 82 px to 54 px (about 34% less).
  Heading gaps, nested chapter separators, card padding and repeated internal margins were reduced
  as one density system rather than by removing content.
- The tallest demonstrations were tightened independently so they retain hierarchy without forcing
  unnecessary scrolling: the control lab is 720 -> 570 px, workflow stage 490 -> 378 px, curve
  editor 620 -> 500 px and final download panel 330 -> 240 px. Gesture rows, resolver rows, setup,
  engineering, voice-detail and observability cards were similarly reduced. Animation timing,
  interaction logic, HTML and JavaScript did not change.
- Only `website/styles.css` was synchronized to the public source mirror and isolated OpenNext
  staging tree. The verified Worker stayed byte-identical at SHA-256
  `d05223bf4d44c84108a102ab62aa3bc9c5568f0c3ac2064c37be5cc65c64bc45`; Wrangler strict dry-run
  passed with all existing D1/KV/R2/Analytics bindings, and production uploaded exactly one modified
  asset: `/siriremote/styles.css`.
- Cloudflare production version is `5bf30dd9-fb6c-4c58-9fd9-49ab33d55407`, message
  `hypervibe-compact-layout`. Production read-back proved the live CSS is byte-for-byte identical to
  the source at SHA-256 `7c315f8dbaf5056896cd5de065205a0197fcfd73af24eaca66f122eb18dbb955`,
  and `/siriremote/` returned HTTP 200 with the complete 47,185-byte page. Browser discovery returned
  no available browser, so this pass does not claim screenshot-level visual QA. The macOS App was
  not rebuilt, installed, restarted or otherwise touched.

## Public beta credentials, app-only Sparkle updates and local.20 verification (2026-08-29)

- Public ad-hoc builds no longer lose native Voice merely because they cannot authenticate the
  certificate-bound credential broker. `VoiceCredentialStore` still prefers the login Keychain
  whenever the App and broker share a certificate requirement; otherwise it uses the dedicated
  plaintext `~/Library/Application Support/HyperVibe/Credentials/credentials.json`. This is not the
  shareable `config.jsonc`: only the Settings credential cards are a supported writer, the directory
  is mode `0700`, the file is mode `0600`, writes are atomic, symlinks are rejected, and the path is
  excluded from backup. The plaintext design is an explicit beta trade-off and does not protect
  against malware already running as the same macOS user.
- The old `--import-voice-keys-from-environment` write path was removed. Explicit API benchmarks may
  still read temporary environment values only when `--test-voice-api` is present; normal App launch
  never imports shell state. Settings explains the actual backend at runtime.
- Sparkle appcasts now sign and enclose the app-only ZIP, not the Full Setup package. Ordinary
  updates therefore replace only `HyperVibe.app`, never restart system audio and do not ask for an
  administrator password. The native/legacy Full Setup assets remain manual choices for installing
  or refreshing the optional microphone stack.
- Release audit now requires the two exact UI-SFX Sci-fi Voice cue hashes and their shipped license.
  Release notes for `0.2.0-beta.6` begin with the one-time manual-upgrade boundary: beta.5 and older
  have no updater; beta.6 begins the authenticated beta channel.
- The active private dictionary retains its six existing terms and now adds canonical `hypergraph`
  (recognition alias `hyper graph`) and `skill`. Both public example configurations include the same
  two beta defaults. The edited live JSONC was parsed through the real `ConfigLoader` before hot
  reload; its pre-edit copy remains in `/private/tmp/hypervibe-keywords.SI1FPw/`.
- `dist/update-appcast.sh` now routes optional key-file arguments through a helper function instead
  of expanding an empty Bash array under `set -u`. This fixes the macOS Bash 3.2 failure that appeared
  only when Sparkle correctly read its private key from the login Keychain.
- Verification so far: app compilation passes; SiriRemoteCore passes **134/134** tests; the complete
  stable-signed bundle passes **73/73** native Voice checks, including local JSON round-trip,
  provider-preserving update, deletion and `0600/0700` permissions. Candidate
  `/private/tmp/HyperVibe-local20.app` passed deep/strict signing and Info.plist validation before
  staging. It is installed as `/Applications/HyperVibe.app` with release
  `1.0.0-local.20`, identifier `com.hypervibe.app`, Authority `siriRemote Local Signing`, and exactly
  one UI process (PID 25016). Startup logs confirm Input Monitoring granted, IOHIDManager open and
  the media event tap installed. The preceding App is recoverable from
  `/private/tmp/hypervibe-local20-install.D9aI8E/HyperVibe.app`.

## beta.6 publication and authenticated feed (2026-08-29)

- Public prerelease `v0.2.0-beta.6` is live at
  `https://github.com/HOLODATA-COM/SiriRemoteForge/releases/tag/v0.2.0-beta.6`. Its tag points to
  source commit `c749175f0a51b2dba29099faae481657513bf7b6`; the release contains the app-only arm64 ZIP,
  native Full Setup PKG, legacy Full Setup ZIP and `SHA256SUMS.txt`.
- A clean isolated checkout produced all three artifacts. Their local SHA-256 verification passed,
  the packaged public App passed **73/73** native Voice checks, and the release audit passed before
  upload. GitHub reports the same digests, and the app-only enclosure resolves publicly with HTTP
  200 and the expected 4,105,276-byte length.
- Commit `ff22296` publishes the byte-identical generated `appcast.xml` only after the release assets
  became available. The beta item uses build `2002006`, channel `beta`, macOS 13 / arm64
  requirements and an Ed25519 enclosure signature. Online `main/appcast.xml` was downloaded and
  compared byte-for-byte with the local signed feed.
- beta.5 and earlier still require one manual beta.6 installation because those binaries do not
  contain Sparkle. Starting with beta.6, authenticated app-only updates can be discovered and
  downloaded automatically; this boundary must remain explicit in future support answers.
- Publication did not install or launch the public ad-hoc bundle locally. The live test App remains
  the deep/strict-valid `/Applications/HyperVibe.app`, Authority `siriRemote Local Signing`, with
  exactly one UI process at the required executable path.

## Voice selector continuity, actionable errors and local.23 (2026-08-29)

- Mute+Side still owns the global, Layer-independent Voice selector. Selector presentation and
  real-hold presentation are now deliberately separate policies: External, Final and Live all show
  in both the persistent widget and temporary Voice selector, so the third destination never looks
  like a disappearing strip. A real Side hold in External still opens no native listening capsule
  and continues through the configured external action.
- A missing OpenAI key is now a first-class `misconfigured` admission result. It consumes only after
  the existing 200 ms Side-button promotion boundary, so quick taps remain ordinary and never flash
  an error. The promoted failure travels through the coordinator's normal phase channel, keeping the
  status widget, Voice capsule and Settings Last-run row on the same actionable error state.
- Provider and transport failures share one safe error vocabulary: missing or invalid key, quota or
  rate limit, unavailable model, server rejection/outage, network loss and timeout. Raw provider
  payloads and request IDs are not echoed. The Settings credential card now expands the actual
  reason below its controls instead of showing only `Test failed`.
- `--test-voice-mode-hud` and `--test-voice-mode-hud-long` provide isolated selector cycles without
  remote, microphone, input hooks or network access. The deterministic Voice suite verifies all
  three selector destinations, External hold suppression, misconfiguration ownership and synthetic
  credential/quota/model/network classification. Command-line screenshots on this multi-Space
  desktop did not capture the isolated status-level panel, so do not claim a fresh pixel-level QC
  recording for this selector; a physical Mute+Side pass remains the final visual check.
- Verification: SiriRemoteCore **134/134**, native Voice **75/75**, production compilation, bundle
  creation and deep/strict signature verification all pass. The stable certificate leaf remains
  SHA-1 `80f746bd1de5a7ceb835a200ce4e43705f01aee6`. The installed App is
  `/Applications/HyperVibe.app`, release `1.0.0-local.23`, and exactly one no-argument UI process is
  running at the required executable path (PID 77041 at handoff time). local.22 is recoverable from
  `/private/tmp/HyperVibe-pre-local23.app`.
- The Xiaohongshu carousel now has three verified 1086 x 1448 (3:4) images: Voice latency, floating
  UI/motion plus the External/Final/Live selector, and the complete point/scroll/click/drag input
  system. Matching copies plus the expanded motion/error copy are in Dropbox; generated project
  artifacts remain under ignored `output/xiaohongshu/` and are not Git release inputs.

## Xcode 16 CI compatibility (2026-08-29)

- CI runs the App job with Xcode 16.4 / macOS 15.5, while the development Mac currently uses
  Xcode 26.6. The newer compiler accepted `@MainActor` on an individual protocol conformance in
  `UpdateManager`; Xcode 16.4 rejected it as an unknown attribute.
- Commit `6156dea` keeps the manager itself main-actor isolated, makes Sparkle's Objective-C user
  driver requirements explicitly `nonisolated`, and returns UI callbacks to `MainActor` before
  touching App state. Only `app/UpdateManager.swift` was committed and pushed; the dirty Voice/HUD
  work and unrelated untracked files were not included.
- Clean `origin/main + UpdateManager` compilation passed locally. GitHub Actions run `33238514638`
  then passed both Core engine and **App (compiles and links)** under the actual Xcode 16.4 runner.
  The only remaining annotations are GitHub's non-failing Node 20 deprecation notices for
  `actions/checkout@v4`.

## Strict Accessibility selection editing and local.24 (2026-08-30)

- Native Voice now branches on the exact Accessibility selection captured at the physical Side
  press. An empty writable selection retains ordinary Final/Live dictation. A non-empty writable
  selection becomes `selectionEdit`: realtime transcription is used only to preview the spoken edit
  instruction and never sends that instruction to the editor; release runs one selected provider
  request and then performs one AX selected-text replacement.
- The replacement is deliberately strict. Immediately before mutation it rechecks the frontmost
  PID, secure-input state, focused AX element (allowing only the existing same-editor semantic
  replacement rule), exact selected text and selected-text writability. This path never simulates
  Copy to discover a selection and never uses paste or Unicode events to pretend an in-place
  replacement succeeded. Readable read-only selections (including terminal output) may still be
  rewritten, but are clipboard-only. If a completed rewrite cannot be replaced because the target
  became read-only/secure, focus or selection changed, or AX failed, the source remains untouched
  and the full rewrite is copied with an explicit reason.
- Selection-edit configuration is additive and JSON-owned:
  `selectionEditingEnabled` defaults true and `selectionEditProvider` defaults `deepseek` (or may be
  `openai`). It reuses the provider's configured text-processing model. Old/partial JSON inherits
  these defaults, GUI write-back preserves them, and validation requires the selected model name.
  `autoInsert=false` is also a visible hard failure for selection editing rather than a copy fallback.
- The model prompt separates `selected_text` and `spoken_instruction` in a typed JSON envelope. Only
  the latter is an instruction channel; selected text is untrusted quoted data. Cloud failure,
  missing credentials, an empty result or an unexpectedly large result aborts without altering the
  selection. Normal Final transcript cleanup keeps its existing loss-minimising fallback behavior.
- Voice Settings now has a dedicated indigo Selection Editing section with an enable switch,
  provider picker, three-step Select → Speak → Release flow and the strict Accessibility guarantee.
  Both floating surfaces retain the real continuous waveform while morphing from red `LIVE` to
  indigo `EDIT`; post-release states are Transcribing → Rewriting Selection → Selection Updated,
  with configurable SF Symbols under `voice.selection.*`. The Settings page was inspected from an
  actual installed-build screenshot after moving its existing multi-display window onto the current
  screen; the new section is aligned, readable and does not force a phone-width layout.
- Verification: SiriRemoteCore **134/134**, native Voice **79/79**, production compilation, default
  and author JSON examples, icon audit, typed-envelope isolation, editable/read-only/unavailable AX
  routing, clipboard-nonmutation on strict failure, bundle construction and deep/strict signature
  verification all pass. The installed App is `/Applications/HyperVibe.app`, release
  `1.0.0-local.24`, certificate leaf remains
  `80f746bd1de5a7ceb835a200ce4e43705f01aee6`, and exactly one UI process is running from the required
  path (PID 15741 at handoff time). local.23 is recoverable at
  `/private/tmp/HyperVibe-before-local24-20260830.app`. Nothing from this feature was pushed.
- Final installed-build QA found that the Voice credentials footer was synchronously revalidating
  the signed Keychain helper whenever SwiftUI recomputed the page. Security.framework reported a
  main-thread performance fault on the 60-second Settings refresh. Backend validation now runs once
  on the existing background credential preload, publishes its cached result through
  `VoiceCredentialModel`, and the view only reads that in-memory state. A real installed Voice page
  was kept open across a full device-refresh interval with zero `com.apple.runtime-issues` entries.
  The rebuilt App remains build 24 / `1.0.0-local.24`, passes **134/134** Core and **79/79** native
  Voice checks plus deep/strict signing, and runs as one process from the required Applications path
  (PID 26460 at final QA). The immediately previous local.24 bundle is recoverable at
  `/private/tmp/HyperVibe-before-security-ui-fix-local24.app`; nothing was pushed.
- local.25 makes clipboard recovery a non-optional loss-prevention invariant for every native Voice
  route. Final, Live reconciliation, automatic-insertion-off, missing targets, secure/changed targets
  and failed AX selection replacement all copy the complete generated result instead of discarding
  it. A readable read-only AX selection now continues through transcription and rewrite, then copies
  the result; an unreadable/secure selection still fails before cloud work because no source text
  exists. The legacy `copyOnFailure` JSON field remains Codable for compatibility but every false
  value is validated then normalised true, and Settings presents a polished non-interactive
  **Always on** recovery row instead of a misleading toggle. Verification: Core **134/134**, native
  Voice **80/80** including a forced failed-delivery clipboard/restore regression, optimized build,
  deep/strict signing and installed Voice-page screenshot. The installed App is build 25 /
  `1.0.0-local.25` with the same certificate leaf. local.24 is recoverable at
  `/private/tmp/HyperVibe-before-local25-clipboard-recovery.app`; nothing was pushed.
- local.27 completes a real installed-build UI/localization audit instead of treating English-only
  screenshots as sufficient. A source-wide audit now finds **442/442** `L(...)` literals with a
  Chinese mapping; the missing credential, read-only-selection, generic App, Off/Test and realtime
  error strings were added. Pixel inspection of the installed Chinese Tuning page additionally
  caught two unwrapped graph labels (`curve` and `drag the three points`), which are now localized
  along with the curve help and linked-shape label. The installed Chinese Voice top/selection-edit
  layout, English Delivery section, and isolated Copied/Error Voice capsules were captured and
  inspected with no clipping, overlap, missing symbol or overflow. Hidden, production-inert QC
  flags provide a non-persistent language override and fixed Copied/Error panel dwell; they open no
  microphone, remote, input hook, network or text target. Verification: Core **134/134**, native
  Voice **80/80**, warning-free optimized compile, `git diff --check`, deep/strict codesigning,
  stable certificate leaf `80f746bd1de5a7ceb835a200ce4e43705f01aee6`, candidate/installed
  binary equality and an empty `com.apple.runtime-issues` log after normal launch. The live App is
  `/Applications/HyperVibe.app`, build 27 / `1.0.0-local.27`, with exactly one no-argument process
  (PID 49691 at handoff time). local.26 and local.25 are recoverable at
  `/private/tmp/HyperVibe-before-local27-ui-complete.app` and
  `/private/tmp/HyperVibe-before-local26-ui-completeness.app`. Nothing was pushed.
- local.30 fixes the paired "External -> Final still behaves like External" and lost selection-edit
  reports. The actual root state divergence was a config-watcher echo from an earlier debounced GUI
  save: it could overwrite a newer in-memory Voice choice after the selector had already confirmed
  Final. `SettingsModel` now rejects a stale tuning reload while a newer tuning save is pending, and
  an isolated regression proves the pending Final choice wins over the older External file. The
  temporary Voice capsule also owns an explicitly cancellable selector-hide task and retargets the
  NSWindow alpha animator, so beginning Final during the selector card's CRT exit cannot leave an
  internally-listening but transparent panel. Selection discovery is positive-evidence based:
  empty/unavailable AX selection metadata no longer labels every editor read-only, while WeChat and
  other custom editors get a bounded, reversible Command-C compatibility probe only when AX exposes
  no non-empty selection. A custom editable role verifies the exact original selection immediately
  before guarded paste replacement; read-only targets and every failed replacement still copy the
  complete generated rewrite. Missing target metadata likewise continues through transcription to
  the existing no-target clipboard delivery instead of discarding the utterance. Verification:
  Core **134/134**, native Voice **83/83**, optimized build, `git diff --check`, deep/strict stable
  signing, candidate/installed binary SHA-256 equality, and the deterministic
  `--test-voice-mode-return-to-final` compositor race (**PASS**). The installed App is build 30 /
  `1.0.0-local.30`, signed by `siriRemote Local Signing`, with one no-argument process from
  `/Applications/HyperVibe.app` (PID 45187 at handoff time). The prior local.27 is recoverable at
  `/private/tmp/HyperVibe-before-local30-selection-and-voice-cycle.app`; local.28/local.29 were
  candidates only and never installed. The user's on-disk Voice mode was preserved as `external`
  (pipeline overlay remains enabled), so the next physical validation must explicitly select Final
  once before holding Side. Nothing was pushed.
- local.45 improves the particle orb's legibility without adding a boundary or changing its motion
  vocabulary. The authored sphere grows from 74 to 84 points, each rendered particle receives an
  additional 1.28 radius multiplier (about 38% larger than the previous 74-point rendering after
  the engine's size scaling), connective strokes are 1.08x thicker, and the transparent HUD surface
  grows from 112x98 to 120x112 so energetic outer-ring hits are not clipped. Verification: Core
  **134/134**, native Voice **112/112**, optimized App compilation, `git diff --check`, candidate and
  installed executable SHA-256 equality
  (`dfff85add1a6f35b7b6f07a687cc55f596ac887358c66f3fb184874f090e978b`), and deep/strict
  codesigning all pass. The installed App is build 45 / `1.0.0`, signed by
  `siriRemote Local Signing`, with one no-argument process from `/Applications/HyperVibe.app`
  (PID 95221 at handoff time). local.44 is recoverable at
  `/private/tmp/hypervibe-before-local45.6hSr1y/HyperVibe.app`; the public beta.7 release was not
  replaced and these local readability changes were not pushed.
- local.47 replaces local.45's oversized 1.28 particle multiplier with the more refined 1.14 scale
  and adds a true behind-window frosted material centred under the orb. Its AppKit `maskImage` is a
  radial alpha field (72% at the centre, smoothly reaching zero at the edge), so there is no glass
  disc or rectangular boundary; it fades in with a new presentation and follows the particles out
  during short-capture reversal. A first build 46 prototype incorrectly used a CALayer mask; live
  composite capture exposed its square blur, so it was rejected and never installed. The corrected
  build 47 was captured against a real busy application background and inspected at
  `/private/tmp/hypervibe-local46-composite.png`: the square is gone, background detail is softened
  most at the centre, and the material continuously disappears toward the outside. Verification:
  Core **134/134**, native Voice **112/112**, optimized compilation, `git diff --check`, deep/strict
  signing, and candidate/installed executable equality all pass (SHA-256
  `dfe351f155bfda8d7c04ba9a5b64cba6ca3b5fe4f7df4c330c665ad5814e0877`). The installed App is
  build 47 / `1.0.0`, signed by `siriRemote Local Signing`, with one no-argument process from
  `/Applications/HyperVibe.app` (PID 1725 at handoff time). build 45 is recoverable at
  `/private/tmp/hypervibe-before-local47.8yXC58/HyperVibe.app`; these changes were not pushed.
- local.49 replaces the centre-heavy local.47 frost with an audio-reactive material envelope. The
  mask has a constant 56% material plateau through the actual authored particle radius and fades
  only across the following 18 points, so the orb interior is even and the outside has no hard
  edge or bright centre. The radius follows the visible authored dots (including pitch-driven ring
  movement), is smoothed independently for expansion and contraction, and is quantised to quarter
  points between 28 and 46 to avoid mask-image churn. The particles now render with semantic
  `labelColor` inside the active vibrant HUD material, letting macOS choose black over bright
  backgrounds and white over dark backgrounds without screen-pixel capture or a new Screen
  Recording permission. Installed-background captures at
  `/private/tmp/hypervibe-local48-dynamic-{0,3,7}.png` confirm black particles over a bright photo,
  the absence of a white centre, and the material growing with the loud-state particle envelope.
  Build 48 used an overly bright material and was rejected without installation. Verification:
  Core **134/134**, native Voice **112/112**, optimized compilation, `git diff --check`, stable
  deep/strict signing, and candidate/installed executable equality all pass (SHA-256
  `5b8259be3619d075d6ba0c2ff318eee8b4213cbfa20e4fe75d67ff5b95d8e8b2`). The installed App is
  build 49 / `1.0.0`, signed by `siriRemote Local Signing`, with one no-argument process from
  `/Applications/HyperVibe.app` (PID 9790 at handoff time). local.47 is recoverable at
  `/private/tmp/hypervibe-before-local49-20260831/HyperVibe.app`; these changes were not pushed.
- local.51 fixes local.49's false assumption that semantic `labelColor` can classify arbitrary
  pixels beneath a floating window. On a black webpage under a light system appearance it could
  still render black particles over a pale HUD material. The orb now owns a deliberately dark,
  neutral vibrant material and keeps every depth layer on the bright side of the active Layer hue;
  this guarantees contrast on both black and bright application content without requesting Screen
  Recording access. The material plateau is only 46% (31% shoulder, 10% tail), so it suppresses
  busy light backgrounds without becoming the obvious grey disc seen in rejected build 50. A
  precompiled, non-interactive black-background fixture covering the lower centre of every display
  was used to catch the Listening animation without timing or cursor-screen ambiguity. Captures at
  `/private/tmp/hypervibe-local51-black-listening-{0,3,7}.png` confirm bright mint/white particles,
  readable audio-driven size changes, no white fog, and no visible circular edge on pure black.
  Verification: Core **134/134**, native Voice **112/112**, optimized compilation,
  `git diff --check`, stable deep/strict signing, and candidate/installed executable equality all
  pass (SHA-256 `3865846624c66d3357542cd2ad92f6f58ca19752a91890c83e4329e5d8d9e543`).
  The installed App is build 51 / `1.0.0`, signed by `siriRemote Local Signing`, with one
  no-argument process from `/Applications/HyperVibe.app` (PID 23363 at handoff time). build 50 is
  recoverable at `/private/tmp/hypervibe-before-local51-20260831/HyperVibe.app`; build 49 is at
  `/private/tmp/hypervibe-before-local50-20260831/HyperVibe.app`. These changes were not pushed.
- local.54 makes the Listening sphere substantially more expressive without restoring fast globe
  rotation. Meter input now removes a 1.2% noise floor, uses a stronger perceptual curve, reaches
  full pitch displacement at 4.5 rather than 7 semitones from its slowly adapting baseline, and
  lets spectral brightness create a coherent three-lobed surface ripple instead of changing only
  dot size. Voiced hits propagate more strongly through the ten delayed latitude samples: outward
  travel reaches about 24%, while inward recoil is deliberately limited to prevent layers from
  collapsing into a central knot. Rise times are faster and releases slightly longer so individual
  syllables hit immediately and continue into neighbouring layers. Rejected build 52 exposed
  excessive inward collapse; build 53 fixed that but live capture showed maximum expansion touching
  the status word. The final build shifts both sphere and material centre up 8 points. Deterministic
  captures at `/private/tmp/hypervibe-local54-reactive-{0,1,2,3}.png` show clearly distinct compact,
  full-sphere and pitch-shaped silhouettes with no clipping or label collision. The native geometry
  regression now requires more than 150 points of aggregate acoustic travel rather than 80.
  Verification: Core **134/134**, native Voice **112/112**, optimized compilation,
  `git diff --check`, stable deep/strict signing, and candidate/installed executable equality all
  pass (SHA-256 `d9b1cff8fe362510873ec7bcd3fae4bcc069176242cd2f55924c22d9f6ec98bf`).
  The installed App is build 54 / `1.0.0`, signed by `siriRemote Local Signing`, with one
  no-argument process from `/Applications/HyperVibe.app` (PID 56811 at handoff time). build 53 is
  recoverable at `/private/tmp/hypervibe-before-local54-20260831/HyperVibe.app`; these changes were
  not pushed.
- local.55 fixes a live-only saturation regression in local.54. The deterministic preview looked
  expressive, but the real microphone's already-curved display envelope was curved and boosted a
  second time, so ordinary speech immediately clipped the sphere at its largest geometry and left
  no headroom for syllables. The orb now reuses the same tested `VoiceWaveformLevelNormalizer` as
  the other Voice surfaces: every hold has a 5.5% acoustic gate, a slowly releasing local peak and
  a hard 0.76 visual ceiling. Geometry maps that unsaturated relative level into wider positional
  travel rather than manufacturing motion by clipping the meter. Spectral brightness is gated by
  real acoustic energy, and dot-size gain is secondary to ring movement. Captures at
  `/private/tmp/hypervibe-local55-dynamic-{0,1,2,3}.png` show a compact first frame, a distinct
  syllable expansion, and two visibly smaller pitch-shaped releases instead of a permanently
  maximum sphere. Verification: native Voice **112/112**, optimized compilation,
  `git diff --check`, stable deep/strict signing, and candidate/installed executable equality all
  pass (SHA-256 `1f2e10d22e7a0a7d75181a8b0b904736d040d2d24de39e342940c34b69bdaec4`).
  The installed App is build 55 / `1.0.0`, signed by `siriRemote Local Signing`, with one
  no-argument process from `/Applications/HyperVibe.app` (PID 70496 at handoff time). The rejected
  build 54 is recoverable at `/private/tmp/hypervibe-before-local55-20260831/HyperVibe.app`; these
  changes were not pushed.
- local.56 decouples overall sphere size from microphone energy. The live Listening sphere has a
  fixed base radius 6% larger than before; volume, pitch and brightness redistribute individual
  latitude layers around that base instead of scaling the whole silhouette. The previous ten
  chronological level samples are reduced to one recent level and one onset impulse, then applied
  to every ring with different deterministic phases. This removes the direct oldest-to-newest,
  south-to-north mapping that made sudden loud sounds visibly sweep down the sphere. Brightness now
  uses a zero-mean local ripple, so it cannot inflate the whole surface either. Deterministic frames
  at `/private/tmp/hypervibe-local56-stable-{0,1,2,3}.png` show simultaneous per-layer changes with
  no vertical scan. Pixel measurement of stable Listening frames finds only about 6% width and 7%
  height variation while their internal ring shapes remain distinct. Verification: native Voice
  **112/112**, optimized compilation, `git diff --check`, stable deep/strict signing, and
  candidate/installed executable equality all pass (SHA-256
  `5881fdde76d8aafd50e1f1e8ceb162a51b0f935788a9afe2f4f6ba212e41a0c5`). The installed App is
  build 56 / `1.0.0`, signed by `siriRemote Local Signing`, with one no-argument process from
  `/Applications/HyperVibe.app` (PID 75090 at handoff time). build 55 is recoverable at
  `/private/tmp/hypervibe-before-local56-20260831/HyperVibe.app`; these changes were not pushed.
- local.57 restores a deliberately small volume-driven whole-sphere breath on top of local.56's
  stable large base. Normalized Voice level contributes only 0...5.5% to every ring's common
  radius; the independent phase-based layer, pitch and timbre deformation remains the dominant
  motion and the removed chronological north/south scan does not return. A new native regression
  constructs otherwise identical quiet and loud acoustic frames and requires the loud envelope to
  be measurably larger while staying under a strict 4.5-point delta. Captures at
  `/private/tmp/hypervibe-local57-breath-{0,1,2,3}.png` show a subtle common breath with simultaneous
  layer changes and no vertical sweep. Stable captured frames vary by about 7% in width and 9% in
  height. Verification: native Voice **113/113**, optimized compilation, `git diff --check`, stable
  deep/strict signing, and candidate/installed executable equality all pass (SHA-256
  `c06942ad76b094002367fae318a32fd5dee9384e17da2466221dc9285d98757c`). The installed App is
  build 57 / `1.0.0`, signed by `siriRemote Local Signing`, with one no-argument process from
  `/Applications/HyperVibe.app` (PID 88933 at handoff time). build 56 is recoverable at
  `/private/tmp/hypervibe-before-local57-20260901/HyperVibe.app`; these changes were not pushed.
- local.60 makes the Listening orb feel like a suspended soft body rather than a rigid globe that
  only zooms. The common volume breath increases from 5.5% to a still-bounded 7.5%, while a lightly
  under-damped level spring adds a small recoil after loud syllables. Energy, onset, pitch and
  spectral brightness drive four different coherent, zero-mean surface modes, so neighbouring
  particles form moving local bulges instead of random noise or the removed north/south scan.
  Particles on an outward crest grow slightly to keep the deformation readable. Installed dark-
  background captures preserved under `/private/tmp/hypervibe-local60-siri-fluid/` show Listening
  envelopes changing from about 163x151 to 173x169 pixels without clipping or touching the status
  label; the later processing, insertion and checkmark transitions also remain clean. A new native
  regression measures true three-dimensional radial spread (about 0.216 quiet versus 0.968 loud)
  and rejects both uniform zoom and unbounded distortion. Verification: native Voice **114/114**,
  optimized compilation, `git diff --check`, stable deep/strict signing, and candidate/installed
  executable equality all pass (SHA-256
  `aedc4fac4c89335ef9e29288aeea15c7520dc92de9ba579544ab4e5facac9465`). The installed App is
  build 60 / `1.0.0-local.60`, signed by `siriRemote Local Signing`, with one no-argument process
  from `/Applications/HyperVibe.app` (PID 27553 at handoff time). build 58 is recoverable at
  `/private/tmp/hypervibe-before-local60-20260901/HyperVibe.app`; build 57 is at
  `/private/tmp/hypervibe-before-local58-20260901/HyperVibe.app`. These changes were not pushed.
- local.61 fixes same-model multi-Siri-Remote teardown. `RemoteDetector` previously collapsed every
  physical device and every one of its HID interfaces into the key `vendorID:productID`; two gen-3
  remotes therefore looked like one connection, and the first removal deleted that shared key and
  sent a global nil callback. `RemoteInputHandler` responded by closing every opened interface,
  including those belonging to the still-connected remote. Detection now registers actual
  `IOHIDDevice` interface identities, emits explicit added/removed/reset events, and derives the
  public connected state from whether any interface remains. A removal closes only that exact
  interface; shared gesture state is safely unwound so a held button on the departing remote cannot
  poison deduplication on the survivor. A deterministic regression creates two same-model remotes
  with multiple interfaces and requires the second to remain connected after all first-remote
  interfaces leave. Current hardware startup could enumerate only one online gen-3 remote
  (`C08RX8PR2330`, five interfaces), and all five were separately registered and seized with no HID
  open failure; the two-device physical disconnect still needs a user hardware confirmation.
  Verification: native Voice **115/115**, optimized compilation, `git diff --check`, stable
  deep/strict signing, and candidate/installed executable equality all pass (SHA-256
  `8d41d259a3496cd57a4d1bb0cd4627e9efe4a494a38156a66c9f02b822621b1a`). The installed App is
  build 61 / `1.0.0-local.61`, signed by `siriRemote Local Signing`, with one no-argument process
  from `/Applications/HyperVibe.app` (PID 69387 at handoff time). build 60 is recoverable at
  `/private/tmp/hypervibe-before-local61-20260901/HyperVibe.app`; these changes were not pushed.

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
