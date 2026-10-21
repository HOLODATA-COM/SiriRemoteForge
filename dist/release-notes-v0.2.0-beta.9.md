# SiriRemoteForge v0.2.0-beta.9

This release upgrades **v0.2.0-beta.8** with safer dictation delivery, a hands-free keyboard
shortcut, Escape cancellation, longer recordings, and a fix for clipped words when releasing the
remote microphone. The existing particle orb and two-remote support remain unchanged.

## Upgrade from beta.8

- **Existing installation:** choose **Check for Updates…** or download
  `HyperVibe-0.2.0-beta.9-macOS-arm64.zip`. All changes in this release are in the App;
  an existing beta.8 Full Setup installation does not need its system audio services reinstalled.
- **First installation:** use `HyperVibe-Full-Setup-0.2.0-beta.9-arm64.pkg`.
- The legacy `HyperVibe-Full-Setup-0.2.0-beta.9-arm64.zip` is also available.

Requires Apple silicon and macOS 13 or later. As with beta.8, public App bundles are ad-hoc signed,
the Installer is unsigned, and these downloads are not Apple-notarized. Use Control-click → Open
for the first launch; never disable Gatekeeper globally. Existing personal configuration and API
credentials are not included in downloads and are not reset by this release.

## What changed since beta.8

### Results no longer disappear behind a misleading clipboard message

- Sending Command-V is no longer treated as proof that the editor inserted the text. Final
  delivery checks Accessibility text and the caret range for the exact expected edit.
- If an editor cannot confirm insertion, the result stays on the clipboard and the UI explicitly
  says insertion is unconfirmed. Another insertion route is not attempted after a dispatched
  paste, avoiding duplicate text.
- Clipboard writes are read back before reporting success. The previous clipboard is restored
  only after confirmed insertion, with a two-second grace period. A newer user copy or Voice
  operation always invalidates older restores.
- Busy editors get realistic focus-query timeouts rather than being immediately mistaken for a
  different target. Actual focus changes and secure fields still block insertion.
- Double-press the remote side button to **paste the previous dictation** into the current target,
  with clipboard fallback if it cannot be inserted. Older `copyLastOnSideButtonDouble` settings
  migrate automatically to `pasteLastOnSideButtonDouble`.
- Diagnostic logs now identify each turn and its final outcome, stage and timings. Clipboard
  diagnostics contain ownership, length and per-process-salted fingerprints, not spoken text or
  clipboard contents.

### Hands-free shortcut, cancellation and ten-minute capture

- Configure **Voice → Keyboard Trigger**: press the shortcut once to start, release it while
  speaking, then press again to stop. Modifier-only shortcuts are supported. The remote retains
  hold-to-talk, and the existing External route remains available.
- Press **Esc** while recording or processing to cancel the entire turn, including any pending
  replacement. Late network responses cannot insert cancelled text. Idle Escape behaves normally.
  Live text already inserted before cancellation cannot be retracted.
- New/default recording limits are ten minutes, with a hard maximum of 600 seconds. Existing
  explicitly configured shorter limits remain respected. Reaching the limit finishes and
  transcribes normally; Escape discards the turn instead.
- Long Final uploads are downsampled only when needed to fit the transcription upload limit;
  ordinary recordings and the retained original audio remain at 24 kHz.

### More reliable capture and bounded processing

- Releasing a valid remote recording briefly drains delayed audio frames (120 ms quiet window,
  320 ms maximum), reducing clipped final words without adding that wait to short discarded turns
  or built-in-microphone recordings.
- A WebSocket ping completion is accepted only once, preventing duplicate-continuation crashes
  during socket teardown.
- A stalled live transcription commit falls back to the complete recorded buffer after five
  seconds rather than fifteen. Optional polishing has a length-dependent budget; on timeout the
  dictionary-corrected transcript is delivered without waiting for the stalled polish request.

## Verification and downloads

- SiriRemoteCore: **136 tests passed**.
- Native Voice: **175 offline self-checks passed**, including isolated clipboard transactions,
  cancellation, insertion confirmation, shortcut classification and long-recording encoding.
- Release packaging independently audits signatures, checksums, versions, payload seals,
  architecture, licenses and the public/private data boundary.
- The signed Sparkle feed and public app-only download are independently verified after publication.

`SHA256SUMS.txt` covers the App ZIP, Full Setup ZIP and Installer:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

This is the macOS HyperVibe release. The separate experimental VoiceInk macOS/Windows project
remains on its own development branch and is not bundled here. Siri Remote voice still requires
Apple's separately installed PacketLogger; the built-in microphone fallback works without it.
