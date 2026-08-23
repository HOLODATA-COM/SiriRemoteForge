# Project operating rules

These rules are non-negotiable for every local macOS App build and test deployment.

1. The only App used for live testing is `/Applications/HyperVibe.app`.
2. After compiling and packaging a user-test build, install that verified bundle at
   `/Applications/HyperVibe.app`. Never launch `app/HyperVibe.app` as the live App.
3. Preserve the existing stable `siriRemote Local Signing` identity. Verify the packaged bundle's
   signature before replacing the installed App.
4. Never silently fall back to ad-hoc signing for a local development build. If the stable identity
   is unavailable or signature verification fails, stop before installation or restart and tell the
   user.
5. Restart only after installation and signature verification, then confirm the single running UI
   process executes `/Applications/HyperVibe.app/Contents/MacOS/HyperVibe`.

Public release artifacts may use their explicitly requested release signing workflow, but must not
be substituted for the stable-signed local development App.
