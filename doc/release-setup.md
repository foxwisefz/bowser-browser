# One-time release setup and routine publishing

## What is implemented

| Component | Build/publish path | Deployment |
| --- | --- | --- |
| Desktop + bundled runtime | Actions: Build desktop release | Draft GitHub Release with signed/notarized DMG, signed stable.json, SHA256SUMS |
| Website, registration, limited telemetry, update hosting | Actions: Build website and API image | GHCR container, Linux amd64 and arm64; operator deploys by digest |
| Web Push | Plan and isolated native delivery probe only | Not ready; subscription provider integration remains open |
| Public component live activation | Follow-up bowser-browser-7xho | Public updater currently stages the full DMG for normal quit/reopen |

Both workflows are manually triggered. Pushing commits alone does not run a
release. No workflow has SSH credentials or deploys to the Ubuntu server.
The server image includes website assets; publishing the image alone does not
change the live website. Local `bin/install` live activation and public DMG
update activation currently differ.

## 1. Configure GitHub once

Push the desired code to the repository's default branch using the project's jj
workflow. In GitHub Settings → Environments create `release`, restrict it to your
trusted release branch, and add these environment secrets:

| Secret | Contents |
| --- | --- |
| APPLE_CERTIFICATE_BASE64 | Exported Developer ID Application .p12, including private key, base64 encoded |
| APPLE_CERTIFICATE_PASSWORD | Password you chose when exporting that .p12 |
| APPLE_SIGN_IDENTITY | Developer ID Application: Foxwise AI FZ-LLC (V7W5LP47U9) |
| APPLE_ID | Apple account email used for notarization |
| APPLE_TEAM_ID | V7W5LP47U9 |
| APPLE_APP_SPECIFIC_PASSWORD | App-specific notarization password, not account password |
| BOWSER_UPDATE_PRIVATE_KEY_BASE64 | Base64 of the persistent 32-byte Ed25519 update signing key |

Export the Developer ID identity from Keychain Access as a password-protected
.p12, selecting the identity with its private key. Keep it outside the repository.
Use stdin to upload files without displaying their contents:

```sh
base64 < /secure/path/developer-id.p12 | tr -d '\n' | gh secret set APPLE_CERTIFICATE_BASE64 --env release
gh secret set APPLE_CERTIFICATE_PASSWORD --env release
# Repeat the interactive command for the other text secrets.
```

Reuse an existing production update signing key if one has been established.
Otherwise generate it once in a private directory outside the repository:

```sh
bin/sign-update --generate-key /secure/path/bowser-update.key
base64 < /secure/path/bowser-update.key | tr -d '\n' | gh secret set BOWSER_UPDATE_PRIVATE_KEY_BASE64 --env release
gh secret list --env release
```

Keep an encrypted offline backup. Changing this key arbitrarily strands installed
clients. The workflow derives and embeds its public key. Apple signing and update
signing are separate and both required. See [distribution](distribution.md).

The server workflow uses GitHub's built-in GITHUB_TOKEN with `packages: write`;
do not create a PAT for CI. Organization policy must permit package publishing.
Initially GHCR packages may be private. For public distribution, make the server
package public; otherwise the Ubuntu host needs a read:packages credential via
`docker login ghcr.io` (kept on the host, not in compose.yaml).

## 2. Build artifacts in Actions

Run **Build website and API image** on the chosen ref. Both native Linux jobs
must pass API tests and container smoke tests before the combined image is
published. The workflow summary prints a commit-tagged image and manifest digest.
Deploy the digest, e.g. `ghcr.io/OWNER/REPO/server@sha256:...`, to avoid mutable tags.

Run **Build desktop release**, entering a new version such as `0.1.0`. It uses
GitHub's macOS arm64 runner, builds the app/runtime, signs and notarizes both app
and DMG, signs update metadata, and creates a draft Release. These are configured
workflows; successful hosted runs must still be verified in your repository.

Review/download `Bowser.dmg`, `stable.json`, and `SHA256SUMS` from the same run.
The DMG is used for both initial installation and updates; no ZIP is needed.
Check the downloaded checksums and test installation/launch from that actual
artifact before making it public. Never alter the DMG after signing its manifest.

## 3. Bootstrap the Ubuntu service once

Copy or check out the matching code under `/home/ubuntu/bowser-browser`. On the
server:

```sh
cd /home/ubuntu/bowser-browser/server
cp -f .env.example .env
chmod 600 .env
mkdir -p downloads
```

Edit `.env`, using the actual GHCR digest from the workflow:

```dotenv
BOWSER_SERVER_IMAGE=ghcr.io/OWNER/REPO/server@sha256:DIGEST
BOWSER_DOWNLOAD_PATH=/downloads/Bowser.dmg
BOWSER_UPDATE_IMAGE=/downloads/Bowser.dmg
BOWSER_UPDATE_MANIFEST=/downloads/stable.json
BOWSER_TERMS_VERSIONS=
BOWSER_TELEMETRY_ENABLED=0
```

Keep registration disabled until the actual Terms are finalized. The current
`website/terms.html` has registered-address/support-email placeholders and is not
effective. An enabled server must accept the exact Terms version embedded by the
desktop onboarding configuration. Choose event retention before enabling telemetry.
These are outstanding product configuration, not GitHub secrets.

Upload the matched DMG and manifest into downloads (initially unavailable routes
return 503). Start only the Bowser service:

```sh
docker compose config --quiet
docker compose pull bowser
docker compose up -d --no-build bowser
docker compose exec bowser curl --fail http://127.0.0.1:8080/healthz
```

Follow [server/README.md](../server/README.md#docker-deployment-on-the-existing-ubuntu-host)
to add the Caddy overlay and top-level site import. Check subnet overlap before
using the supplied network. Preserve both Compose files in future Caddy commands.
This first Caddy network attachment recreates Caddy and briefly interrupts ingress.

Point bowser.app DNS to the Ubuntu host. With Cloudflare proxying, use Full
(strict) TLS. Verify the website, `/healthz`, `/Bowser.dmg`,
`/updates/stable.json`, and `/updates/Bowser.dmg`. Do not configure push.bowser.app
as a working service yet. No push endpoint is implemented in this image.

## 4. Routine releases

For website/API changes: push code, run the server-image workflow, copy its digest
into server `.env`, then run `docker compose pull bowser` and
`docker compose up -d --no-build bowser`. Keep the previous digest for rollback.
Back up SQLite before a release that changes persisted data; see the Admin backup
command in the server README. Keep one replica per SQLite volume.

For desktop changes: run the desktop workflow with a new version, verify its
draft artifacts, then upload DMG and manifest to temporary filenames in the same
downloads directory. Finish uploads before renaming. On Ubuntu:

```sh
cd /home/ubuntu/bowser-browser/server/downloads
# After verified uploads of Bowser.dmg.next and stable.json.next:
mv -f Bowser.dmg.next Bowser.dmg
mv -f stable.json.next stable.json
```

Replace the DMG first and the manifest last. A client racing the two replacements
may fail verification and retry; it cannot install a mismatched image. The
downloads directory is mounted, so replacing its files does not require rebuilding
or restarting the server. Preserve previous artifacts outside this directory for
recovery. A desktop rollback must carry a higher build number.

Publish the reviewed GitHub draft Release when ready. GitHub Release publication
does not activate the bowser.app update feed; serving the new manifest does.
The updater restricts download origins, so do not replace its endpoint with a
redirect to a GitHub asset URL.

Signed manifests expire after 30 days. Renew the manifest with the same private
key and unchanged artifact before expiry, even if no new desktop version ships.
This renewal is currently manual; do not treat the setup as maintenance-free.

## References

[GitHub environment secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets),
[GitHub runner architectures](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
