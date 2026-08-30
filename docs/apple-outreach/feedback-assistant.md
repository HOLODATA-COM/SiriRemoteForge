# Feedback Assistant submissions

Submit these as two separate reports. Apple describes Feedback Assistant as the channel for SDK,
API, tool, and service enhancements: <https://developer.apple.com/feedback-assistant/>.

The category labels can change between OS releases. Choose the closest current macOS developer
technology category, then preserve the titles and technical separation below.

## Report 1 - supported Siri Remote input on macOS

**Suggested title**
Enhancement request: supported macOS API for paired Siri Remote button, ring, and touch input

**Classification**
Enhancement / macOS / Developer Technologies / Game Controller or Human Interface Device

**Environment**

- macOS: 26.5.1 (25F80; reconfirm on the submission machine)
- Hardware: Apple silicon Mac
- Accessory: third-generation USB-C Siri Remote, paired over Bluetooth
- Xcode/SDK: Xcode 26.6 (17F113), macOS SDK 26.5 (reconfirm when filing)
- Sample project: `PublicAPIProbe/InputProbe`

**Problem**

A paired third-generation Siri Remote can be useful as a compact alternative input surface for
Mac accessibility, standing presentations, and voice-assisted workflows. Game Controller already
documents a Siri Remote profile and second-generation Siri Remote support for Apple TV. In our
macOS testing with the third-generation Remote, however, that public model does not provide the
complete input needed for this experience. Button-like events can be partially observed through
lower-level HID interfaces, but the complete touch-surface stream used by the system is not
available to our app through a supported public API with stable semantics. There is also no
documented application routing model for intentionally capturing the remote without conflicting
with system behavior.

**Steps to observe the limitation**

1. Pair a third-generation Siri Remote with a Mac over Bluetooth.
2. Run the attached minimal app and enumerate publicly supported Game Controller and HID inputs.
3. Press each physical button, rotate/tap the click-ring, and move one finger across the touch
   surface.
4. Compare the public events with the input needed to implement pointer movement, circular
   scrolling, click-and-drag, and reliable button down/up state.

**Current result**

On the tested macOS environment, no public API delivered a complete, documented third-generation
Siri Remote input profile. The working proof of concept must combine raw HID behavior with private
MultitouchSupport behavior to obtain the touch stream, which is not suitable for a sandboxed or
durable product.

**Expected result**

Extend the existing Siri Remote model in GameController/GCPhysicalInputProfile to the paired
third-generation Remote on macOS, or provide an equivalent documented accessory-input framework.
It should expose:

- connection, disconnection, stable identity, battery, and capability discovery;
- timestamped button down/up events for Menu/Back, TV, Play/Pause, Mute, Power, volume, ring
  directions, and center click where available;
- normalized touch coordinates, contact begin/move/end, contact size or a documented click/pressure
  signal, and multitouch capability where the hardware supplies it;
- a documented distinction between outer-ring gestures and general surface motion;
- an opt-in routing policy for foreground, background, exclusive, and system-shared use; and
- a sandbox-compatible permission or entitlement model suitable for accessibility input software.

**User impact and use case**

The attached HyperVibe demonstration uses the surface for pointer acceleration, precise and fast
ring scrolling, sticky drag, App x Layer commands, and visible hold feedback. This allows a user to
continue operating a Mac after voice input and allows a presenter to control a live Mac while away
from the desk. The limitation is not a missing interaction design; it is the absence of a supported
API path for an interaction that already works as a public proof of concept.

**Attachments**

- 60-second MP4 with no personal desktop content
- one-page PDF
- `PublicAPIProbe` source and scrubbed `InputProbe` console output
- a scrubbed capability/event matrix; omit Bluetooth addresses, serials, and unrelated packet logs

**Public references**

- Demo: PUBLIC_DEMO_URL
- Source: https://github.com/HOLODATA-COM/SiriRemoteForge
- Current release: https://github.com/HOLODATA-COM/SiriRemoteForge/releases/tag/v0.2.0-beta.5
- Existing Siri Remote model: https://developer.apple.com/documentation/gamecontroller/gcmicrogamepad
- Apple TV example: https://developer.apple.com/documentation/gamecontroller/letting-players-use-their-second-generation-siri-remote-as-a-game-controller

---

## Report 2 - supported Siri Remote microphone route on macOS

**Suggested title**
Enhancement request: permissioned Siri Remote microphone capture on macOS

**Classification**
Enhancement / macOS / Developer Technologies / Core Audio or Bluetooth

**Environment**

- macOS: 26.5.1 (25F80; reconfirm on the submission machine)
- Hardware: Apple silicon Mac
- Accessory: third-generation USB-C Siri Remote, paired over Bluetooth
- Xcode/SDK: Xcode 26.6 (17F113), macOS SDK 26.5 (reconfirm when filing)
- Sample project: `PublicAPIProbe/AudioInputProbe`

**Problem**

The third-generation Siri Remote contains a close-talk microphone, but a paired remote does not
appear as a supported macOS audio input and there is no documented public API to request a
permissioned push-to-talk stream from it. The microphone can therefore not be used by standard
CoreAudio/AVAudioEngine clients, accessibility tools, dictation workflows, or conferencing apps on
the Mac.

**Steps to observe the limitation**

1. Pair the Siri Remote with a Mac.
2. Run the attached `AudioInputProbe`, which enumerates CoreAudio devices with input streams using
   only public APIs.
3. Inspect the reported device names, UIDs, manufacturers, transport types, and nominal rates.
4. Hold the remote's Siri button and repeat the enumeration. If any new public endpoint appears,
   attempt to select it in a standard permissioned CoreAudio capture client.

**Current result**

No supported remote microphone input or accessory stream is available. The HyperVibe research
prototype can demonstrate voice capture only by interoperating with an undocumented Bluetooth
voice path and routing decoded audio through a virtual CoreAudio device. That implementation is
fragile across OS versions and requires diagnostics tooling that cannot be redistributed.

**Expected result**

Provide either a standard CoreAudio input endpoint or a documented accessory-audio API that offers:

- explicit user permission and a clear recording indicator;
- a documented push-to-talk activation and release lifecycle;
- sample format, clock, buffering, interruption, and route-change semantics;
- connection-loss and fallback events so an app can move to the Mac microphone without pretending
  remote audio is still live;
- coexistence rules for Siri/system use and third-party capture; and
- a sandbox-compatible entitlement and review path.

**User impact and use case**

A supported route would let one controller cover both command input and close-talk speech. In the
working HyperVibe interface, holding the side button opens a live 25-bar voice surface while the
same device remains available for pointer, scrolling, and command actions. When remote audio is not
fresh, the app falls back to the Mac's built-in microphone. A public route would make that behavior
reliable, permissioned, and usable by ordinary Mac audio clients.

**Attachments**

- 60-second MP4 and one-page PDF
- `PublicAPIProbe` source and scrubbed `AudioInputProbe` console output
- scrubbed input-device list and relevant sysdiagnose collected through Feedback Assistant
- do not attach public packet captures, credentials, Bluetooth addresses, or serial numbers

**Public references**

- Demo: PUBLIC_DEMO_URL
- Source: https://github.com/HOLODATA-COM/SiriRemoteForge
- Current release: https://github.com/HOLODATA-COM/SiriRemoteForge/releases/tag/v0.2.0-beta.5
- Technical background: https://github.com/HOLODATA-COM/SiriRemoteForge/blob/main/docs/mic-reverse-engineering.md
