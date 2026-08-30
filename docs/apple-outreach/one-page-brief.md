# HyperVibe

## Complete one-handed control for macOS, using Siri Remote

HyperVibe is a working public macOS proof of concept. It combines pointing, scrolling, clicking,
dragging, contextual commands, and voice in one compact controller - with every action visible and
every mapping configurable.

### The gap

Voice can create a prompt, but it cannot finish the interaction. Coding agents, live demos, and
mobility workflows still require a mouse or trackpad to navigate, scroll, select, drag, change apps,
or confirm what happened. A speaker also loses presence whenever they have to return to the laptop
to operate a presentation.

### What works today

- **Touch plus ring:** pointer movement with a tunable acceleration curve; accelerated vertical or
  horizontal ring scrolling; click, tap, and sticky drag.
- **A complete gesture grammar:** tap, double tap, triple tap, and up to three timed long-press
  stages on configurable inputs.
- **App x Layer context:** the same physical control changes with the frontmost app and any of up to
  ten named, colored layers.
- **State you can trust:** a compact persistent widget and optional HUDs show the real layer, action,
  hold progress, connection state, system state, and live voice activity.
- **Voice plus fallback:** experimental Siri Remote voice capture can feed a virtual Mac input, with
  the built-in microphone used when remote audio is unavailable.
- **Agent-friendly by design:** the native GUI, scripts, and coding agents edit the same hot-reloaded
  JSONC configuration.

### Why it matters

1. **Voice-assisted coding:** speak, navigate the result, scroll, select, and approve without
   breaking the workflow to reach for another device.
2. **Standing presentations:** remain in the room as a speaker while controlling slides, a live app,
   the pointer, and a demo Mac.
3. **Alternative Mac input:** concentrate common pointing and command tasks in one small,
   configurable, one-handed surface.

### The platform request

The proof of concept demonstrates the interaction, but not a supportable distribution path. Apple
documents Siri Remote game input for Apple TV; in our macOS testing, full third-generation Remote
touch input still depends on private MultitouchSupport behavior, while remote voice uses an
undocumented Bluetooth path. HyperVibe asks Apple to consider supported, permissioned macOS APIs
for paired Siri Remote button/ring/touch input and microphone capture, with a sandbox-compatible
entitlement and routing model.

### Public evidence

macOS 13+ on Apple silicon | third-generation USB-C Siri Remote | public source and beta releases |
native installer and live permission checks | current reviewed tree: 130/130 core tests

Repository: https://github.com/HOLODATA-COM/SiriRemoteForge
Demo: PUBLIC_DEMO_URL
Contact: Wenqian Zhang - zhangwenqian6915@gmail.com

This is an existing public, non-confidential research project. Remote voice is experimental and
depends on undocumented system behavior; the public API requests are filed separately through
Feedback Assistant.
