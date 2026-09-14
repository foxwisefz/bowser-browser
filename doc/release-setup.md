# One-time release setup and routine publishing

## What is implemented

| Component | Build/publish path | Deployment |
| --- | --- | --- |
| Desktop + bundled runtime | Actions: Build desktop release | Draft GitHub Release with signed/notarized DMG, signed stable.json, SHA256SUMS |
| Website, registration, limited telemetry, update hosting | Actions: Build and deploy website and API | GHCR container, Linux amd64 and arm64; deploys by digest over Tailscale SSH |
| Web Push | Plan and isolated native delivery probe only | Not ready; subscription provider integration remains open |
| Public component live activation | Follow-up bowser-browser-7xho | Public updater currently stages the full DMG for normal quit/reopen |

The desktop workflow is manually triggered. Website/API changes pushed to `main`
automatically build and deploy; the server workflow also supports manual runs.
Only `main` deploys. Production jobs are serialized. The server image includes
website assets. Local `bin/install` live activation and public DMG update
activation currently differ.

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
The deployment job sends its short-lived, read-only GITHUB_TOKEN over Tailscale
SSH to `docker login` using a disposable Docker config, deleted when deployment
finishes. No persistent GHCR token or SSH private key is needed on the server.

### Tailscale deployment identity

In the `release` environment, add `TS_OAUTH_CLIENT_ID` and `TS_AUDIENCE` secrets
from the Tailscale OIDC credential. It needs Auth Keys write scope and
`tag:bowser-ci`. Restrict its subject to this repository's `release` environment;
use the exact GitHub subject format for the repository (new repositories include
immutable owner/repository IDs). Keep the environment restricted to `main`.
The deployment job requests `id-token: write` and uses Tailscale's ephemeral runner.

Optional environment variables (these are also the defaults):

| Variable | Value |
| --- | --- |
| BOWSER_DEPLOY_HOST | 100.109.207.69 |
| BOWSER_DEPLOY_USER | ubuntu |
| BOWSER_DEPLOY_DIR | /home/ubuntu/bowser |

Use the Tailscale IP to avoid dependency on the runner's MagicDNS resolver. If
`BOWSER_DEPLOY_HOST` is already set in GitHub, update that variable too; it overrides
the workflow default.

On the server, run `sudo tailscale set --ssh`. The server keeps `tag:lobsterfarm`.
Define `tag:bowser-ci` in tagOwners; grant it TCP 22 to `100.109.207.69`, and
Tailscale SSH `accept` to `tag:lobsterfarm` as `ubuntu`. Retain existing rules.
The `ubuntu` user must be able to run Docker without interactive sudo. Docker
access grants host-level privileges; the CI tag restricts network reach, not the
privileges of this deployment account.

## 2. Build artifacts in Actions

Run **Build and deploy website and API** on `main`. Both native Linux jobs must
pass API and container smoke tests before publication. The deployment job joins
Tailscale, transfers Compose/Caddy configuration, pulls the published digest, and
starts only Bowser with `--no-build --wait`. It creates `.env` from defaults only
if missing, preserving subsequent operator settings, downloads and named volumes.
The default configuration leaves registration and telemetry disabled.

Run **Build desktop release**, entering a new version such as `0.1.0`. It uses
GitHub's macOS arm64 runner, builds the app/runtime, signs and notarizes both app
and DMG, signs update metadata, and creates a draft Release. These are configured
workflows; successful hosted runs must still be verified in your repository.

Review/download `Bowser.dmg`, `stable.json`, and `SHA256SUMS` from the same run.
The DMG is used for both initial installation and updates; no ZIP is needed.
Check the downloaded checksums and test installation/launch from that actual
artifact before making it public. Never alter the DMG after signing its manifest.

## 3. Bootstrap the Ubuntu service once

The first successful deployment creates `/home/ubuntu/bowser`, a healthy service,
and the `bowser_edge` Docker network. The host needs Docker Engine with Compose
v2 supporting `up --wait`, Bash, tar and flock; it does not need source code,
Elixir, or build tooling. Before the first run, check that `172.30.29.0/29` does
not overlap existing Docker networks.

After that run, edit `/home/ubuntu/bowser/.env` to configure downloads:

```dotenv
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

Upload the matched DMG and manifest into `downloads/`. To apply `.env` edits:

```sh
cd /home/ubuntu/bowser
docker compose --env-file image.env up -d --no-build --wait bowser
```

Attach Caddy once, after Bowser's first healthy deployment:

```sh
cp -f /home/ubuntu/bowser/deploy/caddy.compose.yaml /home/ubuntu/lobsterfarm-backend/compose.bowser.yaml
cp -f /home/ubuntu/bowser/deploy/bowser.caddy /home/ubuntu/lobsterfarm-backend/config/bowser.caddy
```

Add `import /etc/caddy/bowser.caddy` at the top level of the existing Caddyfile,
outside the global options block. Then:

```sh
cd /home/ubuntu/lobsterfarm-backend
docker compose -f docker-compose.yml -f compose.bowser.yaml config --quiet
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose -f docker-compose.yml -f compose.bowser.yaml up -d --no-deps caddy
```

This first network attachment briefly recreates Caddy. Preserve both Compose
`-f` arguments in future Caddy commands and its deploy.sh. Routine Bowser deploys
do not change or restart Caddy. See the server README for proxy trust details.

Point bowser.app DNS to the Ubuntu host. With Cloudflare proxying, use Full
(strict) TLS. Verify the website, `/healthz`, `/Bowser.dmg`,
`/updates/stable.json`, and `/updates/Bowser.dmg`. Do not configure push.bowser.app
as a working service yet. No push endpoint is implemented in this image.

## 4. Routine releases

For website/API changes, push to `main`; GitHub builds and deploys automatically.
A failed pull leaves the service alone. A failed health check fails the workflow;
it can leave the new container running/unhealthy and does not automatically roll
back database changes. The last successful reference remains in `image.env`,
with the preceding release in `previous-image.env` and `previous-compose.yaml`.
For an explicit rollback after a successful deployment:

```sh
cd /home/ubuntu/bowser
docker compose --env-file previous-image.env -f previous-compose.yaml up -d --no-build --wait bowser
```

Back up SQLite before data migrations and check schema compatibility before a
rollback. Keep one replica per SQLite volume. A successful container health check
does not prove public DNS/TLS/Caddy works; verify `https://bowser.app/healthz`
after the initial Caddy attachment.

For desktop changes: run the desktop workflow with a new version, verify its
draft artifacts, then upload DMG and manifest to temporary filenames in the same
downloads directory. Finish uploads before renaming. On Ubuntu:

```sh
cd /home/ubuntu/bowser/downloads
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
