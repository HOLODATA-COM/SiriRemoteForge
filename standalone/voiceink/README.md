# VoiceInk

An independent, open-source, bring-your-own-key voice typing app for macOS and Windows.
Ported from SiriRemoteForge's native Voice pipeline; no Siri Remote, HID seizure, private
multitouch framework, microphone driver, account, or subscription service is required.

## First version

- System microphone (or a selected input device), up to 10 minutes per turn; the limit ends
  recording and transcribes the captured speech. Long uploads use 16 kHz PCM to stay below 25 MB.
- Global shortcut: **Command + Shift + Space** on macOS, **Control + Shift + Space** on Windows.
  Press once to start, again to stop; configure a modifier-plus-key shortcut in Settings.
- **Esc cancels the entire current turn**, while recording or processing, without delivering its
  result. Escape is registered globally only during active turns; it keeps its normal use otherwise.
- Particle sphere with symmetric ring breathing, speech-driven size/brightness, randomized
  simultaneous particle entrance, and smooth per-particle transitions to check/copy/error shapes.
- OpenAI file transcription (`gpt-transcribe` by default), optional OpenAI or DeepSeek cleanup.
  Models are editable because account access differs.
- Selected text plus spoken instruction edits the selection; focus/selection/password guards
  prevent typing into a different field. Unavailable delivery keeps the result for manual copy.
- Network deadlines, original-transcript fallback when cleanup fails, in-memory audio retry,
  cancellation and replacement of an in-progress network turn.
- Optional local history (100 entries); optional last 20 examples **for the same application**
  sent as cleanup context. Manual history corrections feed subsequent context.
- System tray, single-instance behavior, and independent settings/credentials.

This version implements the **Final** pipeline. HyperVibe's live WebSocket transcription,
automatic monitoring of edits in other apps, remote-specific audio routing and External voice
mode are not part of this standalone first version. HyperVibe itself remains unchanged.

## First run

1. Open Settings → API keys, save your OpenAI API key, and use Test to verify authentication.
2. For DeepSeek cleanup, also save a DeepSeek key; otherwise choose OpenAI or no cleanup.
3. On macOS, allow Microphone when first recording and Accessibility for text insertion.
   The permissions row requests Accessibility. New app identifier means a separate grant from
   HyperVibe; repeated local builds must retain the same signing identity.
4. Focus a normal editor, press the shortcut, speak, then press it again. A recording shorter
   than one second is discarded without sending audio.
5. Closing the settings window leaves VoiceInk in the tray. Quit from its tray menu.

Clicking Start in the settings window records a test and leaves text in the result/clipboard;
use the global shortcut from the destination app for automatic insertion. On Windows, normal
privilege apps cannot paste into elevated apps. Password fields are refused. If accessibility
or editor integration is unavailable, copy the result manually.

## Privacy and credentials

API keys are stored under `com.holodata.voiceink` in macOS Keychain / Windows Credential Manager.
Keys are never returned to the frontend, written into JSON, or embedded in artifacts. Saving a
blank field never deletes a key; deletion is an explicit action. No keys are imported from
HyperVibe. There is no plaintext fallback when system secret storage fails.

Recordings stay in memory only. Starting a recording sends no audio until it is stopped and
passes the minimum duration. Audio then goes directly to OpenAI; cleanup/selection text goes
directly to the selected provider. The settings page names these destinations. Provider-side
retention and API billing are governed by your provider account. OpenAI Responses requests use
`store: false`; this does not promise zero provider-side retention.

History and context sharing are off by default. Enabling history stores transcripts and final
text in the app's private config directory; enabling context sharing sends the recent same-app
examples with cleanup requests. Turning off history deletes its file contents. Clear History
also removes the retained retry recording. Clipboard output persists until replaced by you;
VoiceInk does not silently restore away a transcript before an editor can paste it.

## Development

Requires Node 22+, Rust stable, platform build tools and the Tauri 2 prerequisites.

```sh
npm ci
npm run build
npm test
cargo test --locked --manifest-path src-tauri/Cargo.toml
npm run tauri -- dev
```

The browser preview (`npm run dev`) deliberately cannot record, access API keys, or insert text.
The real frontend is restricted to packaged local assets; no remote content or remote IPC access.

## Packaging

```sh
# macOS local development: always retain the stable signing identity
APPLE_SIGNING_IDENTITY='siriRemote Local Signing' npm run package:macos

# Windows, in a Windows build environment with the MSVC toolchain
npm run tauri -- build --bundles nsis --target x86_64-pc-windows-msvc
```

The local macOS script verifies the stable signature and creates a signed, read-only DMG and ZIP
under `artifacts/`, without Finder Automation permissions. Optionally set
`VOICEINK_EXPECTED_CERT_SHA1` to enforce the precise certificate fingerprint between builds.
Other platform artifacts are under `src-tauri/target/release/bundle/` (or
`src-tauri/target/<target>/release/bundle/` when a target is supplied).
The repository's `voiceink.yml` workflow builds and tests both platforms and uploads artifacts;
it does not create public releases. Windows installers produced without a signing certificate
are unsigned test builds. Public distribution should add Windows signing and macOS Developer ID
signing/notarization. Do not replace HyperVibe with VoiceInk or run a public unsigned artifact as
the stable local HyperVibe App.

## Validation boundaries

Unit checks cover WAV PCM boundaries, response parsing, scoped context limits, unsafe cleanup,
and sphere symmetry/entrance. A successful build is not an end-to-end dictation test: microphone
permissions, API account/model access and actual focused-editor delivery need runtime testing
on each OS. Keep this distinction in release notes.

## License and origin

GPL-3.0-or-later; see LICENSE and NOTICE. Original Voice workflow and cleanup policy:
SiriRemoteForge, Copyright (C) 2026 Wenqian Zhang. Tauri and dependencies retain their own
licenses. The particle renderer is implemented here in canvas; it does not bundle the
Thinking Orbs library. No BlackHole or proprietary Apple libraries are included.

Official implementation references:

- https://developers.openai.com/api/docs/guides/speech-to-text
- https://developers.openai.com/api/docs/guides/text
- https://v2.tauri.app/plugin/global-shortcut/
- https://v2.tauri.app/distribute/
