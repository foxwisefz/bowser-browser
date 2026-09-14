# Bowser website and API

Standalone Elixir 1.18+ / Phoenix 1.8 service, independent of the desktop BEAM process. Bandit serves HTTP; Exqlite/SQLite stores registrations on a persistent local volume. The
existing `website/` directory is served from an explicit public-file allowlist.

From `server/`:

```sh
mix deps.get
mix test
PHX_SERVER=true BOWSER_DATABASE=/absolute/persistent/path/bowser.sqlite mix phx.server
# Build a self-contained release (includes website assets):
MIX_ENV=prod mix release
PHX_SERVER=true _build/prod/rel/bowser_server/bin/bowser_server start
```

The default listener is `127.0.0.1:8080`. `PORT` and `HOST` override it. Do not
expose the plain HTTP listener to the internet. Keep one service process per
SQLite file on a local filesystem, with a persistent disk; this is not an
in-memory or ephemeral/serverless deployment.

## Registration

`POST https://bowser.app/v1/registrations`, Content-Type `application/json`,
`Idempotency-Key` equal to `requestID` (UUID; case-insensitive).

```json
{
  "requestID": "ba89d925-878c-48ed-b5c2-00f9ce3f4924",
  "email": "person@example.com",
  "termsVersion": "YOUR_EFFECTIVE_TERMS_VERSION",
  "acceptedAt": "2026-09-11T10:00:00Z",
  "trainingConsent": false,
  "device": {
    "model": "Mac14,5",
    "architecture": "arm64",
    "macOSVersion": "15.0",
    "appVersion": "1.0",
    "appBuild": "42"
  }
}
```

This matches `RegistrationRequest` in native onboarding. `device` may be omitted.
Unknown keys, including `privacyVersion`, are rejected. No email verification
occurs, no promotional subscription is created, and email is never used as proof
of ownership or to look up an existing person's registration.

Set `BOWSER_TERMS_VERSIONS` to a comma-separated list of effective versions to
enable registration. With no versions the service returns 503. The repository's
Terms page is still a draft; do not configure it as effective before its
outstanding operator details are resolved. The native first-run activation and
endpoint selection remain a separate onboarding task.

A new request returns 201 with `{"registrationID":"UUID"}`; retries return 200
with the same ID. An immediate database transaction and unique request ID protect
concurrent retries. Reusing a request ID with different normalized fields returns
409. A fresh request ID can produce a new record for the same unverified email.
Accepted payload and client time are recorded alongside the server's UTC receipt
time. Keep accepted versions configured for retries against those versions.

Errors have the shape `{"error":{"code":"..."}}` and never echo the payload:
400 invalid request/JSON/key, 404 unknown route, 405 wrong method, 413 body over
16 KiB, 415 wrong media type/encoding, 422 unsupported Terms version, 429 rate
limit (Retry-After: 60), 503 registration unavailable, 500 internal error. Limits
are 20 API requests per client per fixed minute, bounded to 10,000 in-memory
client keys. Counters reset on service restart; the edge must supply additional
abuse protection for public traffic. No request-body or IP access logging is
enabled by this service.

## Docker deployment on the existing Ubuntu host

The recommended package is `Dockerfile` plus `compose.yaml`. It builds an OTP
release with website assets, runs as UID 10001, and persists SQLite in `bowser_data`.
No public ports are published. Only Caddy connects over the dedicated `bowser_edge`
network. This service stays independent of the desktop browser and other backends.

Copy this repo (or at least `server/` and `website/`) to `/home/ubuntu/bowser-browser`.
Build on the Ubuntu host so the release and SQLite native library match its CPU.
The Docker build context allowlist excludes credentials, local databases, and
unrelated browser code. Keep one replica per SQLite volume.

```sh
cd /home/ubuntu/bowser-browser/server
cp -f .env.example .env
mkdir -p downloads
# Edit .env: leave registration and telemetry disabled until configured.
docker compose config --quiet
docker compose up -d --build
docker compose ps
# Optional isolated fixture test (temporary container + volume, no production writes):
python3 test/docker_smoke.py
docker compose exec bowser curl --fail http://127.0.0.1:8080/healthz
```

The example network uses `172.30.29.0/29`. Check `docker network inspect` for
existing networks first. If it overlaps, change the subnet/IP range, the Caddy
address in `deploy/caddy.compose.yaml`, and `BOWSER_TRUSTED_PROXY` in `compose.yaml`
together. Bowser trusts only Caddy's fixed `172.30.29.2` address; other containers
cannot choose a forwarded client address. Do not attach unrelated services to
this network or publish port 8080. `BOWSER_INTERNAL_HTTP=1` explicitly allows HTTP
inside this private network; HTTPS terminates at Caddy.

Integrate with the existing **lobsterfarm-backend** project:

```sh
cp -f deploy/caddy.compose.yaml /home/ubuntu/lobsterfarm-backend/compose.bowser.yaml
cp -f deploy/bowser.caddy /home/ubuntu/lobsterfarm-backend/config/bowser.caddy
cd /home/ubuntu/lobsterfarm-backend
```

Add `import /etc/caddy/bowser.caddy` at the top level of the existing Caddyfile,
after its global `{ ... }` block. Preserve all existing sites and the catch-all.
The exact `bowser.app` site takes precedence over the partner-domain catch-all;
it uses normal automatic HTTPS, not the partner-domain verification endpoint.

In the existing global `servers` block, add `trusted_proxies_strict` alongside
the existing Cloudflare ranges. Keep those ranges current (including IPv6 if
Cloudflare can connect over IPv6). Caddy then resolves `{client_ip}` from trusted
proxy hops and overwrites `X-Real-IP` for Bowser. Without a trusted proxy it uses
the direct peer. See [Caddy proxy trust](https://caddyserver.com/docs/caddyfile/options)
and [client IP forwarding](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy).

```sh
# This merges with the existing project; review before applying.
docker compose -f docker-compose.yml -f compose.bowser.yaml config --quiet
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
# Recreates only Caddy to attach its additional network; briefly interrupts ingress.
docker compose -f docker-compose.yml -f compose.bowser.yaml up -d --no-deps caddy
```

Keep both `-f` flags in future Caddy deployment commands, including `deploy.sh`,
so it retains the Bowser network. The Bowser project must start first because
it creates that network. Existing services remain on `lobsterfarm_net`.
[Compose external networks](https://docs.docker.com/compose/how-tos/networking/).

Point `bowser.app` DNS at this host, with ports 80/443 reachable. If proxied by
Cloudflare, use Full (strict) origin TLS. Verify `https://bowser.app/healthz` and
the landing page, then enable the configured API and exercise it with a designated
test registration. This change has not connected to or modified the remote host.

The pasted infrastructure credential should be rotated in Cloudflare. Store its
replacement in the existing stack's private environment file; this package
neither requires nor includes that credential. Never commit either `.env` file.

For local development without Docker, `Caddyfile` is an alternative loopback
proxy configuration. Do not use its `127.0.0.1` upstream inside the existing Caddy
container. Direct Phoenix TLS is also supported with `BOWSER_TLS_CERT` and
`BOWSER_TLS_KEY`; non-loopback HTTP requires the explicit private-network opt-in.

Set `BOWSER_DOWNLOAD_PATH` to the approved distribution DMG to enable the landing
page's `/Bowser.dmg` links. For Docker, place it in `server/downloads/` and set `BOWSER_DOWNLOAD_PATH=/downloads/Bowser.dmg`. The file is streamed, not loaded into memory. Without
an artifact the route returns 503 rather than serving a development binary.

## Limited telemetry

Owner-approved categories: registration completion, ModSmith outcomes, and crash
categories. The desktop sender now records registration completion, observed ModSmith
outcomes, and WebContent process crash categories. It persists at most 100 events
for 24 hours, retries with backoff, and gives each saved app its own queue. It never
attaches page URLs, prompts, source code or crash logs. Set
`BOWSER_TELEMETRY_ENABLED=1` and choose `BOWSER_EVENT_RETENTION_DAYS` (1–365) to
accept events; otherwise `/v1/events` returns 503. There is deliberately no
invented production retention default. Expired events are deleted at startup,
every minute, and during ingestion; server receipt time determines expiry.

`POST https://bowser.app/v1/events` takes `{"events":[...]}` with 1–25 events.
Each event has `eventID` (UUID), `name`, `occurredAt` (UTC ISO8601), and
`properties`. An event older than the retention window is rejected. Accepted
batches return 202 with `{"accepted":N,"duplicates":M}`. Event IDs deduplicate
retries within retention; conflicts return 409 and roll back the entire batch.

| name | properties |
| --- | --- |
| `registration_completed` | `appVersion`, `appBuild` |
| `modsmith_outcome` | versions, `operation`: create/refine/undo, `outcome`: succeeded/failed/cancelled; optional `durationMs` (0–3600000), `failureCategory` for failed outcomes: provider/timeout/validation/runtime/unknown |
| `crash` | versions, `category`: native/backend/mod/unknown |

Version/build strings permit only 1–64 letters, digits, dots, underscores,
pluses or hyphens. All other fields and event names are rejected, including
URLs, page content, prompts, generated code, email, raw stack traces and error
messages. No model training pipeline is implemented.

Registration responses now also include `telemetryToken`. The native registration store persists this token and attaches it when available. It is a bearer capability **only for attribution of
telemetry**, not account authentication or proof that the email is controlled.
Clients pass `Authorization: Bearer TOKEN`; invalid tokens get 401.
No header means anonymous events with no persistent device identifier. The secret
is generated once in SQLite, so tokens survive process restarts and backups.
Registration retries return the same token. Keep tokens out of logs.

## Operator data tools

Run locally with access to the database; no public read/admin endpoints exist:

```sh
# Against a running release (same user/environment):
# Docker prefix: docker compose exec bowser /app/bin/bowser_server rpc ...
bin/bowser_server rpc 'BowserServer.Admin.run("backup", "/backups/new-snapshot.sqlite")'
bin/bowser_server rpc 'BowserServer.Admin.run("prune-events")'
bin/bowser_server rpc 'BowserServer.Admin.run("withdraw-training", "REGISTRATION_UUID")'
bin/bowser_server rpc 'BowserServer.Admin.run("delete-registration", "REGISTRATION_UUID")'
# Development: mix run -e 'BowserServer.Admin.run("prune-events")' 
```

Backup uses SQLite VACUUM INTO for a consistent snapshot and refuses an existing destination.
Restrict database and backup access, and choose an off-host backup schedule and
retention policy before launch. To restore, stop the service, replace the entire
database/WAL pair with the standalone backup (no stale WAL sidecars), then start
and verify `/healthz`. Backup encryption, provider retention and physical media
purging are deployment responsibilities; deleting a row does not erase older
backups or guarantee forensic removal from storage.

Training withdrawal changes current permission while retaining the original
acceptance record for audit/idempotency. A retry never re-enables permission.
Deletion removes the registration and associated events and revokes its telemetry
token. A later fresh signup can create another record. Anonymous events are
removed by expiry because they carry no user identity. Establish an appropriate
support verification process; an unverified email or supplied registration UUID
alone must not authorize disclosure or deletion.

Registration retention, backup deletion, support verification and effective Terms
remain operator decisions under `bowser-browser-bx4h`. Deploy the public website
with both APIs disabled until the desired service configuration is set.

## Verification

`mix test` passes 12 contract, persistence and runtime-configuration tests.
The production release passed HTTP smoke checks. The Docker image was built
and tested on Linux arm64: non-root/read-only runtime, website, registration,
telemetry, backup RPC and persistence across container replacement all passed.
Both Compose files and the Caddy site fragment were validated. Build on the
Ubuntu host for its architecture; remote deployment has not been performed.
