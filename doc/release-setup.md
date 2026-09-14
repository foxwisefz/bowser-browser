# One-time release setup and routine publishing

## What is implemented

| Component | Build/publish path | Deployment |
| --- | --- | --- |
| Desktop + bundled runtime | Actions: Build desktop release | Signed/notarized DMG and signed feed published to R2; draft GitHub Release also retained |
| Website, registration, limited telemetry | Actions: Build and deploy website and API | GHCR container, Linux amd64 and arm64; deploys by digest over Tailscale SSH |
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
if missing, preserving subsequent operator settings and named volumes.
The default configuration leaves registration and telemetry disabled.

Run **Build desktop release**, entering a new version such as `0.1.0`. It uses
GitHub's macOS arm64 runner, builds the app/runtime, signs and notarizes both app
and DMG, signs update metadata, and creates a draft Release. These are configured
workflows; successful hosted runs must still be verified in your repository.

The `publish-assets` job downloads the matched build artifacts, verifies the
Ed25519 signature and DMG hash/size, and publishes to R2 automatically on `main`.
Running the desktop release workflow therefore publishes a public release, even
though the separate GitHub Release record is a draft. No ZIP is needed. Never
alter the DMG after signing its manifest.

### R2 assets setup

The bucket is `bowser`, with custom domain `assets.bowser.app`. In Cloudflare,
create an R2 API token with **Object Read & Write**, restricted to this bucket.
Add these GitHub `release` environment secrets:

| Secret | Value |
| --- | --- |
| R2_ACCOUNT_ID | Cloudflare account ID from the R2 overview/S3 endpoint |
| R2_ACCESS_KEY_ID | R2 token's S3 Access Key ID |
| R2_SECRET_ACCESS_KEY | R2 token's S3 Secret Access Key |

`R2_BUCKET` is an optional environment variable defaulting to `bowser`. The
publisher uses the S3 endpoint for uploads and the custom domain for public URLs.
Keep R2 credentials in GitHub, not on Ubuntu. Leave `r2.dev` access disabled.

Public paths:

- `https://assets.bowser.app/releases/BUILD/Bowser.dmg`: immutable build artifact.
- `https://assets.bowser.app/Bowser.dmg`: current marketing download.
- `https://assets.bowser.app/updates/stable.json`: signed update feed.

In Cloudflare Cache Rules, bypass cache for `/Bowser.dmg` and
`/updates/stable.json` on `assets.bowser.app`. The publisher also sets `no-store`
on these mutable objects. Build-specific DMGs have a one-year immutable cache
header. Do not override these with a blanket cache rule; Cloudflare can otherwise
serve stale objects or cached 404s. Purge existing cached failures if needed.


## 3. Bootstrap the Ubuntu service once

The first successful deployment creates `/home/ubuntu/bowser`, a healthy service,
and the `bowser_edge` Docker network. The host needs Docker Engine with Compose
v2 supporting `up --wait`, Bash, tar and flock; it does not need source code,
Elixir, or build tooling. Before the first run, check that `172.30.29.0/29` does
not overlap existing Docker networks.

After that run, edit `/home/ubuntu/bowser/.env` for the effective Terms and telemetry
configuration. Release assets are hosted on R2; Ubuntu needs no download paths,
files, mounts or R2 credentials.

Keep registration disabled until the actual Terms are finalized. The current
`website/terms.html` has registered-address/support-email placeholders and is not
effective. An enabled server must accept the exact Terms version embedded by the
desktop onboarding configuration. Choose event retention before enabling telemetry.
These are outstanding product configuration, not GitHub secrets.

To apply `.env` edits:

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
do not change or restart Caddy. When the site's Caddy configuration changes,
copy the new fragment and validate/reload it explicitly:

```sh
cp -f /home/ubuntu/bowser/deploy/bowser.caddy /home/ubuntu/lobsterfarm-backend/config/bowser.caddy
cd /home/ubuntu/lobsterfarm-backend
docker compose -f docker-compose.yml -f compose.bowser.yaml exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose -f docker-compose.yml -f compose.bowser.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile
```

See the server README for proxy trust details.

Point `bowser.app`, `www.bowser.app`, and `api.bowser.app` DNS to the Ubuntu host.
The `assets.bowser.app` custom domain belongs to R2, not Caddy. With Cloudflare
proxying the Ubuntu sites, use Full (strict) TLS. Verify the apex redirect,
`https://www.bowser.app/`, and `https://api.bowser.app/healthz`. After publishing a
desktop release, verify the download and feed on `assets.bowser.app`.
No Web Push endpoint is implemented in this image.

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
does not prove public DNS/TLS/Caddy works; verify `https://api.bowser.app/healthz`
after the initial Caddy attachment.

For desktop changes, run **Build desktop release** on `main` with a new version.
The publication job uploads a build-specific DMG, reads it back to verify its
signed size/hash, saves the build's manifest, updates `/Bowser.dmg`, and promotes
`/updates/stable.json` last. The signed feed always references an immutable DMG,
so a client fetching during promotion can still download the exact signed bytes.
Failed uploads cannot promote the feed. Older builds cannot replace newer ones;
a retry reuses matching immutable bytes. Conditional writes protect feed promotion.

No SSH, scp, Ubuntu restart, or container rebuild is involved in publishing DMGs.
If only `publish-assets` fails, correct its configuration and rerun failed jobs
within the artifact retention period. A new full run must use a new version
because GitHub draft release tags are not overwritten. Keep previous build objects
for clients that already fetched their manifests. A desktop rollback requires a
new signed release with a higher build number.

Signed manifests expire after 30 days. Renew the manifest with the same private
key and unchanged artifact before expiry, even if no new desktop version ships.
This renewal is currently manual; do not treat the setup as maintenance-free.

## References

[GitHub environment secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets),
[GitHub runner architectures](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
