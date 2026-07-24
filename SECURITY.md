# Security policy

## Scope

This app runs unsandboxed with Accessibility permission and can synthesize input, run shell commands
and AppleScript, and seize a HID device. Treat a `config.jsonc` from someone else as you would treat
a shell script from someone else: `shell` and `applescript` bindings run whatever they say.

The app does not phone home, and reads nothing beyond your config, the remote, and the display list.

## Reporting a vulnerability

Please do **not** open a public issue for anything exploitable. Use GitHub's private reporting —
**Security → Report a vulnerability** on this repository — and include what an attacker would need
(local access, a crafted config, a paired device) and what they gain.

Expect an initial reply within about a week. This is a hobby project maintained by one person, so
please size your expectations accordingly.

## Supported versions

Only `main` is supported. There are no backports.
