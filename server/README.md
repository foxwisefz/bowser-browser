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
