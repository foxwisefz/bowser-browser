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

## Signed update channel

The native app checks `https://bowser.app/updates/stable.json` at startup at most
once daily, and from **Check for Updates…**. It verifies an Ed25519 signature
against the public key embedded in the installed app, checks build ordering,
macOS compatibility and expiry, then asks before downloading. It verifies the
DMG's signed length and SHA-256 before mounting it read-only and checking the
bundle signature/build. The existing updater stages the complete app/runtime;
activation waits until Bowser and saved apps quit. Current browsing is preserved.

Create a signing key **once on the release signing machine**, outside the repo:

```sh
bin/sign-update --generate-key /secure/path/bowser-update.key
# The command prints the PUBLIC key. Keep the private file backed up securely.
BOWSER_UPDATE_PUBLIC_KEY=PUBLIC_BASE64_KEY bin/install
bin/package-dmg /path/to/updates/build.ABC123 /tmp/Bowser.dmg
bin/sign-update /secure/path/bowser-update.key /tmp/Bowser.dmg VERSION BUILD 15 /tmp/stable.json
```

Use the exact version and build in the packaged app's Info.plist. The initial
installed release must already contain the public key. Builds without that key
skip background checks and show an unavailable message for manual checks.
Never place the private key in an image, app, server directory or repository.
A replacement key must be delivered through an already trusted release.

Copy the DMG and manifest to the server's read-only `downloads/` mount and set:

```sh
BOWSER_UPDATE_MANIFEST=/downloads/stable.json
BOWSER_UPDATE_IMAGE=/downloads/Bowser.dmg
```

Restart only the Bowser server after configuration changes. Publish the DMG
before atomically replacing the manifest; a client fetching during replacement
may retry, but a mismatched image cannot install. Manifests expire after 30 days;
re-sign the current release before expiry. Rollbacks require a **higher build
number** signed release. Existing staged updater `.previous` copies remain local
recovery artifacts. Public DNS/server deployment, Developer ID/notarization,
and production signing-key provisioning are separate activation steps.

Validation: `swift test --package-path shell --filter UpdateTests` covers signed
metadata, wrong-key/tamper rejection, expiry, downgrade prevention and image
size/hash checks. `tests/test_apply_update.py` covers staged activation/rollback.
