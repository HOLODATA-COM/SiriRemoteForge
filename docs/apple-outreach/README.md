# Apple outreach package

This directory contains a ready-to-review outreach package for **HyperVibe**, the macOS application
published in the SiriRemoteForge repository. It presents the project as an existing, public,
non-confidential proof of concept and as concrete feedback about Apple products and developer APIs.
It is not written as a confidential product proposal.

## Recommended order

1. File the two enhancement requests in [`feedback-assistant.md`](feedback-assistant.md). Keep one
   technical request per report and add the resulting Feedback IDs to the email.
2. Publish the English demo page at `website/apple/` to a public URL. Do not send Apple a Tailnet-only
   address.
3. Send [`email-accessibility.md`](email-accessibility.md) to
   [`accessibility@apple.com`](mailto:accessibility@apple.com), attaching only the one-page PDF and
   linking to the public demo, repository, release, and Feedback IDs.
4. If useful, submit a shortened version through [Apple Product Feedback](https://www.apple.com/feedback/)
   under macOS or Apple TV. Do not duplicate the two technical API reports there.

Apple explicitly lists the Accessibility Feedback address for enhancement requests and user stories:
[Apple Accessibility Support](https://support.apple.com/en-us/111749). API and SDK enhancements belong
in [Feedback Assistant](https://developer.apple.com/feedback-assistant/).

## Files

- [`email-accessibility.md`](email-accessibility.md) - primary email, subject line, and a shorter
  follow-up.
- [`one-page-brief.md`](one-page-brief.md) - editable source for the one-page attachment.
- [`feedback-assistant.md`](feedback-assistant.md) - two independently fileable API enhancement
  reports.
- [`samples/PublicAPIProbe`](samples/PublicAPIProbe) - buildable Game Controller and CoreAudio
  probes that use public Apple frameworks only.
- [`demo-script-60s.md`](demo-script-60s.md) - animation-only, 60-second product demonstration.
- [`public-audit.md`](public-audit.md) - approved claims, claims that require qualification, and the
  final send checklist.
- [`HyperVibe-Apple-Overview.pdf`](../../output/pdf/HyperVibe-Apple-Overview.pdf) - rendered one-page
  attachment.
- [`website/apple/index.html`](../../website/apple/index.html) - public English product page prepared
  for Apple reviewers.

## Fixed facts used throughout

- Product: HyperVibe, distributed from the public SiriRemoteForge repository.
- Host: macOS 13 or later on Apple silicon.
- Accessory: third-generation USB-C Siri Remote paired over Bluetooth.
- Core control: pointer movement, click, sticky drag, accelerated circular scrolling, button/ring
  mappings, app-aware profiles, and configurable layers.
- Gesture grammar: tap, double tap, triple tap, and up to three release-to-select hold stages.
- Feedback: compact always-on status widget plus optional hold and layer HUDs.
- Voice: an experimental Siri Remote microphone path with automatic built-in microphone fallback;
  the remote path depends on an undocumented protocol and separately obtained Apple diagnostics
  tooling.
- Configuration: one hot-reloaded JSONC file shared by the GUI, scripts, and coding agents.
- Current evidence: public beta releases, native installer, source, and release audits; the reviewed
  working tree passes 130/130 core tests, while public beta.5 accurately records its earlier
  129/129 suite.

## Before sending

- Replace `PUBLIC_DEMO_URL` in the email and Feedback reports with the final public HTTPS address.
- File the two Feedback reports and insert their IDs.
- Reconfirm the recorded macOS, Xcode, and SDK versions, then attach the probe source and scrubbed
  output to the corresponding Feedback reports.
- Confirm the current public release still resolves at
  <https://github.com/HOLODATA-COM/SiriRemoteForge/releases/tag/v0.2.0-beta.5>.
- Open the PDF and all public links from a signed-out browser.
- Attach only the PDF. Keep source archives, packet logs, device identifiers, and private diagnostics
  out of ordinary email.
