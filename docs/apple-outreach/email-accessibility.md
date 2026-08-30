# Primary email

**To:** accessibility@apple.com
**Subject:** Accessibility feedback: complete one-handed Mac control using Siri Remote

Dear Apple Accessibility Feedback team,

My name is Wenqian Zhang. I develop HyperVibe, a public macOS proof of concept that turns a paired
third-generation Siri Remote into a complete, configurable input surface for the Mac.

I built it around a simple gap: voice input is increasingly capable, but a voice-first coding,
presentation, or mobility workflow still breaks the moment someone needs to point, scroll, select,
drag, switch context, or confirm a result. At that point the user has to return to a mouse or
trackpad. HyperVibe keeps those actions in one small controller:

- the touch surface moves the pointer, clicks, and supports press-and-hold dragging;
- the outer ring provides accelerated vertical or horizontal scrolling;
- each button can carry tap, double-tap, triple-tap, and staged long-press actions;
- App x Layer mappings change controls with the active task;
- a persistent status surface makes the current layer, action, hold progress, and live voice state
  visible; and
- one JSONC configuration is shared by the native GUI, scripts, and coding agents.

The result has been especially compelling in two situations: standing presentations, where the
speaker no longer has to return to the laptop to drive a demo, and voice-assisted coding, where the
controller remains useful after the prompt has been spoken.

The prototype also exposes a platform limitation. Apple documents Siri Remote game input for
Apple TV, but in our macOS testing the public frameworks do not provide the complete paired
third-generation Remote input stream or a microphone route. The current research build therefore
relies on private MultitouchSupport behavior for touch input and an undocumented Bluetooth voice
path. That prevents the work from becoming a durable, sandbox-compatible Mac input option.

I am sharing an existing public project and concrete accessibility/developer feedback, not a
confidential product idea. Would the Accessibility, Input, or relevant developer-framework teams be
willing to review the working demonstration and consider supported macOS APIs for:

1. paired Siri Remote button, ring, and touch-surface input; and
2. permissioned Siri Remote microphone capture as a standard audio input or accessory stream?

Demo: PUBLIC_DEMO_URL
Source: https://github.com/HOLODATA-COM/SiriRemoteForge
Current release: https://github.com/HOLODATA-COM/SiriRemoteForge/releases/tag/v0.2.0-beta.5
Feedback Assistant: INPUT_FEEDBACK_ID and AUDIO_FEEDBACK_ID

I have attached a one-page overview. I would be happy to provide a short live demonstration or a
minimal diagnostic project through the appropriate Apple channel.

Best regards,

Wenqian Zhang
GitHub: https://github.com/JamesZwq
Email: zhangwenqian6915@gmail.com

---

# Short follow-up

**Subject:** Follow-up: Siri Remote as a supported Mac accessibility input

Dear Apple Accessibility Feedback team,

I am following up on the public HyperVibe proof of concept I shared on DATE. It demonstrates
pointer movement, accelerated ring scrolling, click-and-drag, contextual button layers, visible
hold feedback, and voice input from one paired Siri Remote.

The two concrete API requests are filed as INPUT_FEEDBACK_ID and AUDIO_FEEDBACK_ID. The 60-second
demonstration is available at PUBLIC_DEMO_URL, and the source remains public at
https://github.com/HOLODATA-COM/SiriRemoteForge.

If another Apple team is the correct owner for this feedback, I would appreciate being routed to
that team.

Best regards,
Wenqian Zhang
