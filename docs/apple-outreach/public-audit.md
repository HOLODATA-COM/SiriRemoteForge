# Public claims and send audit

## Claims that are supported by the current public project

| Claim | Evidence in the project | Approved wording |
| --- | --- | --- |
| Touch surface controls the pointer | `TouchHandler`, current Tuning UI, public README | "Pointer movement with tunable acceleration" |
| Ring scrolling has acceleration | independent circular-scroll curve and current Tuning capture | "Accelerated circular scrolling with an independent curve" |
| Vertical and horizontal ring scrolling | configuration and Layer behavior | "The same ring can scroll vertically or horizontally by context" |
| Rich button gestures | tap/double/triple plus three hold stages | "Up to six configured intents on one input" |
| App and Layer context | app-mode resolver and 1-10 layer loop | "App x Layer mappings" |
| Persistent visual feedback | compact widget, hold HUD, layer HUD, current videos | "Current action, layer, hold progress, and voice state remain visible" |
| Remote voice path exists | virtual device/router/capture pipeline and installer | "Experimental remote voice capture with built-in mic fallback" |
| Agent-friendly configuration | hot-reloaded JSONC and GUI write-back | "GUI, scripts, and agents share one configuration" |
| Current build quality | public release audit and current-tree tests | "Public beta, native installer, release audits, and 130/130 tests in the current reviewed tree" |

## Claims that must stay qualified

- **Microphone:** always call the remote path experimental. State that it uses an undocumented
  Bluetooth voice path and separately obtained Apple diagnostics tooling. Do not imply that it is a
  supported CoreAudio accessory.
- **Distribution:** say that the current proof of concept uses private/undocumented behavior and is
  distributed directly. Do not claim that Apple has rejected it or that an App Store path is
  categorically impossible forever.
- **Existing API surface:** acknowledge that Game Controller documents a Siri Remote profile and a
  second-generation Remote example for Apple TV. The observed request is specifically the complete
  paired third-generation Remote input surface on macOS, plus a supported audio route.
- **Accessibility:** describe concrete alternative-input and mobility use cases. Do not claim
  clinical outcomes, certification, user-study results, or endorsement by disabled users without
  evidence.
- **Performance:** use qualitative language for acceleration and responsiveness unless a public,
  repeatable benchmark is attached.
- **Test count:** the current reviewed tree passes 130/130 tests; beta.5's public notes correctly
  record the 129/129 suite that existed when that release was cut. Do not attribute the later count
  to the older release.
- **Agent operation:** say that agents can edit the same configuration. Do not imply that an agent
  controls private user data or can bypass macOS permissions.

## Wording to remove or avoid

- Hardware material claims such as "glass". The software only needs to describe the **touch
  surface** or **clickpad**.
- "Can never ship on the App Store." Replace with the precise current limitation: private input
  behavior, undocumented remote voice, Accessibility/Input Monitoring, and the need for a supported
  sandbox/entitlement path.
- "Apple-quality," "official," "Apple approved," or language that could imply affiliation.
- "SOTA microphone," "zero latency," "works everywhere," or "replaces every input device."
- Any confidential roadmap, API key, packet capture containing identifiers, private Tailnet URL, or
  personal desktop recording.

## Apple submission posture

Apple's [Unsolicited Idea Submission Policy](https://www.apple.com/legal/intellectual-property/policies/ideas.html)
says not to send unsolicited proprietary ideas and treats submitted feedback as non-confidential.
Accordingly:

- present HyperVibe as an already public implementation and a concrete report about existing Apple
  products and missing developer API support;
- ask for review, routing, and supported APIs rather than acquisition, compensation, secrecy, or
  ownership of an idea;
- keep each API enhancement in its own Feedback Assistant report; and
- send only material that is already public or intentionally non-confidential.

## Final public-page checks

- The first screen identifies the product and working interaction without a giant generic slogan.
- Every native clip uses the latest capture, is muted, loops, and has a meaningful still state.
- Pointer, ring, drag, gestures, App x Layer, voice, curves, and Agent configuration all appear.
- The page says "touch surface," not "glass."
- Browser Back timing shows `Delete -> Back at 0.5 s -> Close at 1.0 s -> Quit at 1.7 s`.
- Public source and Release links work while signed out.
- `PUBLIC_DEMO_URL`, `INPUT_FEEDBACK_ID`, and `AUDIO_FEEDBACK_ID` are replaced, and the recorded OS,
  Xcode, and SDK versions are reconfirmed before submission.
- Both `PublicAPIProbe` executables are rebuilt on the reported environment, and their console output
  is scrubbed before attachment.
- The email carries one PDF attachment only; diagnostics go through Feedback Assistant.
