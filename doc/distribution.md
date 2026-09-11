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

## GitHub Actions builds

`.github/workflows/desktop-release.yml` builds on GitHub's Apple Silicon
`macos-26` runner. Run **Actions → Build desktop release → Run workflow**, with
a version such as `0.1.0`. The workflow tests the release contracts, creates a
fresh standalone app/runtime, packages `Bowser.dmg`, signs `stable.json`, and
uploads both plus `SHA256SUMS` as workflow artifacts and a **draft GitHub Release**.
Use a new version for each run: existing release tags/assets are not overwritten.
[GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Create a GitHub environment named `release` and add its secret
`BOWSER_UPDATE_PRIVATE_KEY_BASE64`. Generate the key once with `bin/sign-update
--generate-key /secure/path/bowser-update.key`; then set the secret without
printing its value:

```sh
base64 < /secure/path/bowser-update.key | tr -d '\n' | gh secret set BOWSER_UPDATE_PRIVATE_KEY_BASE64 --env release
```

Keep an encrypted backup of that same private key outside GitHub. The workflow
derives the matching public key and embeds it in every build, restores the private
key into a mode-0600 temporary file, and removes it afterward. The key is never
included in artifacts. Restrict the `release` environment to trusted release
branches. [GitHub Actions secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets).

`bin/install --stage-only` is the build entry point. It always uses a new temporary
home, reads no installed runtime, and does not publish a pending update or register
LaunchAgents. `BOWSER_VERSION` and `BOWSER_BUILD` supply artifact identity;
`BOWSER_STAGE_FILE` receives the completed stage path for subsequent packaging.

The first workflow produces an **ad-hoc-signed test DMG**, not an Apple-notarized
public distribution. Update metadata signing and Apple Developer ID/notarization
are separate. Draft release notes call out this limit; public signing remains an
activation requirement. This workflow does not connect to the Ubuntu host or
change DNS. Copy its matched DMG/manifest to the configured `bowser.app` endpoints
as described above. A GitHub Release URL alone will not work with the current
updater's origin and redirect restrictions.
