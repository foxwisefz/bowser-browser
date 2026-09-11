# Desktop DMG

`bin/install` produces a complete unpublished stage and prints its path.
Package that exact pair without accessing profile, session or credential data:

```sh
bin/package-dmg /path/to/updates/build.ABC123 /tmp/Bowser.dmg
```

The image contains `Bowser.app` and an Applications shortcut. The app includes
its BEAM release and native helpers in `Contents/Resources/runtime`; clean
machines do not need Elixir, Python, developer tools, or a preinstalled runtime.
User data remains under `~/.bowser`. Mobile experiments are rejected by the
packaging script. Existing external development installations still work.

By default this creates an ad-hoc-signed local testing artifact. It is not a
publicly distributable notarized release. `BOWSER_SIGN_IDENTITY` selects a
signing identity; Developer ID/hardened-runtime entitlements and notarization
still need release validation before public distribution.
