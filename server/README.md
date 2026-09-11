# Bowser website and API

Standalone Node 24.14+ service, independent of the desktop BEAM process. No npm
dependencies. SQLite stores registrations on a persistent local volume. The
existing `website/` directory is served from an explicit public-file allowlist.

From the repository root:

```sh
node --test server/test/*.test.js
BOWSER_DATABASE=/absolute/persistent/path/bowser.sqlite node server/src/main.js
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

## HTTPS deployment for bowser.app

Use a host with a persistent disk, Node 24.14+, and Caddy. Copy `server/` and
`website/` together, run the service as an unprivileged user under a supervisor,
and keep its data outside the release directory. Set `BOWSER_TRUSTED_PROXY` to
`127.0.0.1` only when Caddy is the local edge, as in the included Caddyfile. All
other forwarded client-IP headers are ignored. Do not place an additional CDN
in front without updating and testing the proxy trust policy.

Point bowser.app's A/AAAA records at the host, allow inbound TCP 80/443 (and UDP
443 for HTTP/3 if desired), then run `caddy validate --config server/Caddyfile`
and install that configuration through Caddy's service manager. Caddy obtains
and renews HTTPS certificates when DNS and the network reach the server.
[Caddy automatic HTTPS](https://caddyserver.com/docs/automatic-https).
The configured proxy overwrites `X-Real-IP` from its connection peer.
[Caddy reverse proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy).

Check `https://bowser.app/healthz` and the website, then exercise registration
with a designated test email and an effective Terms version. Do not post fixture
registrations to production as part of routine unit tests. No host, DNS record,
public certificate or deployment has been provisioned by this repository change.

The service can also terminate TLS directly: set both `BOWSER_TLS_CERT` and
`BOWSER_TLS_KEY` to PEM files, then choose `HOST`/`PORT`. Non-loopback plaintext
listeners are rejected. The HTTPS test generates a one-day certificate in a
throwaway directory and verifies it as a CA; it never disables TLS verification.
Caddy remains the automatic-certificate deployment path. Its configuration has
not been executed here because Caddy is absent and the Docker daemon is stopped.

Set `BOWSER_DOWNLOAD_PATH` to the approved distribution ZIP to enable the landing
page's `/Bowser.zip` links. The file is streamed, not loaded into memory. Without
an artifact the route returns 503 rather than serving a development binary.

## Limited telemetry

Owner-approved categories: registration completion, ModSmith outcomes, and crash
categories. No client sender is installed by this change. Set
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

Registration responses now also include `telemetryToken`. The existing native
registration decoder tolerates additional response keys, but does not yet store
or transmit this token. It is a bearer capability **only for attribution of
telemetry**, not account authentication or proof that the email is controlled.
A future client may pass `Authorization: Bearer TOKEN`; invalid tokens get 401.
No header means anonymous events with no persistent device identifier. The secret
is generated once in SQLite, so tokens survive process restarts and backups.
Registration retries return the same token. Keep tokens out of logs.

## Operator data tools

Run locally with access to the database; no public read/admin endpoints exist:

```sh
BOWSER_DATABASE=/persistent/bowser.sqlite node server/src/admin.js backup /backups/new-snapshot.sqlite
BOWSER_DATABASE=/persistent/bowser.sqlite node server/src/admin.js prune-events
BOWSER_DATABASE=/persistent/bowser.sqlite node server/src/admin.js withdraw-training REGISTRATION_UUID
BOWSER_DATABASE=/persistent/bowser.sqlite node server/src/admin.js delete-registration REGISTRATION_UUID
```

Backup uses SQLite's online backup API and refuses an existing destination.
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
