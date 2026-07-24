# Contributing

Thanks for taking an interest. This is a small, opinionated project — the notes below are less about
process and more about the handful of things that are easy to get wrong here.

## Getting set up

```bash
git clone https://github.com/HOLODATA-COM/SiriRemoteForge.git
cd SiriRemoteForge
swift test --package-path SiriRemoteCore   # engine tests, no hardware needed
cd app && ./build.sh && ./create_app_bundle.sh
```

`SiriRemoteCore/` is dependency-free SwiftPM with unit tests, and is where most logic belongs.
`app/` is compiled directly with `swiftc` — the core sources are compiled into the same binary, so
adding a file to `app/` means adding it to the `SWIFT_FILES` list in `app/build.sh`.

You need the hardware (a 3rd-gen Apple TV Siri Remote) and Accessibility permission to run it, but
not to work on the engine.

## What to know before you change behaviour

- **Only one instance may run.** It *seizes* the remote's HID interfaces, so a second process gets
  nothing and the first stops responding. Kill before you launch.
- **The `--test-*` flags do not seize the remote.** They render a HUD for screenshotting and exit.
  Restore your normal instance afterwards.
- **Validate `config.jsonc` after editing it.** A malformed file falls back to defaults *silently*.
  `ExampleConfigTests` guards the shipped example; your own config is on you.
- **Resolution order is load-bearing.** Layers and presentation both resolve through rules that
  exist because of specific bugs — read the "Layers" and "Labels and icons" sections of the README
  before changing `Controller.site(_:)` or `MappingEngine`. Those rules are pinned by tests.
- **Prefer measuring over reasoning for UI geometry.** Screenshot it and check the pixels. Several
  alignment "fixes" in this repo's history were confident and wrong.

## Pull requests

- Put logic in `SiriRemoteCore` with a test where you can; that is the part that can be tested
  without hardware.
- Say what you actually verified, and on what. "Builds" and "works on my remote" are different
  claims, and both are useful — but only if you say which one you mean.
- Keep commit messages explanatory: what changed, and *why* it was wrong before.
- CI must be green.

## Reporting bugs

Include your macOS version, whether the remote is connected over USB-C or Bluetooth, the relevant
part of your `config.jsonc`, and what `/tmp/hypervibe.log` says. A binding that "doesn't work" is
almost always visible there.
