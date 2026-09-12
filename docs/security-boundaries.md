# Security boundaries

## Native mods and generated code

Elixir mods run inside Bowser's BEAM runtime with the user's OS privileges.
Compiling Elixir executes code, including module-body expressions and macros.
A host declaration, profile tag, AST inspection, or successful LLM audit does
not sandbox a mod. Source and stored-data checks on ModSmith tools constrain
those tools; arbitrary running Elixir can bypass them and access other runtime
services, credentials, files, and processes.

Webpage content and tool results are untrusted input to generation. Generated
Elixir is gated by an independent tool-free LLM audit before file installation
or compilation. Only a strict allow verdict for the exact source/hash/nonce is
accepted; review failure or uncertainty blocks activation. This is the chosen
audit-only policy, not enforced isolation. Accepted mods retain OS privileges.
An enforced capability boundary is planned separately.

## Local access and secrets

Local socket directories are mode `0700`, and socket files are mode `0600`.
The native listener also verifies the peer's effective UID. These controls
exclude other OS users; they do not authenticate applications running as the
same user. Settings remain plaintext in private `0600` files and accessible
inside the BEAM runtime. Bowser does not currently use Keychain-backed mod
capabilities or an application sandbox.

Cookie IPC requires an HTTP(S) target and a known profile or live webview.
Cookie domains match the requested host exactly or at a dot boundary; a blank
target cannot export the whole jar. Session snapshots retain their profile
when restored. HttpOnly cookies remain available to native browser tools,
including authenticated downloads. This is privileged access, not webpage
JavaScript access. Downloader cookie files are private and removed when the
download task finishes or raises.

`Bridge.get_cookies(url, timeout \\ 5000)` uses the caller mod's profile, or the
active profile for an unscoped core caller. `get_cookies_for(url, profile,
timeout \\ 5000)` selects an explicit profile; scoped callers cannot select
another profile. `set_cookie(url, cookie, profile \\ nil)` follows the same
ownership rule. These checks do not isolate arbitrary Elixir in the same VM.

## Website-initiated actions

Non-web application links require a native confirmation for each request.
Subframes and unmounted views cannot display that confirmation. Native favicon
fallback only connects to validated public addresses, pins the connection to
the checked address, and validates each redirect. This restriction applies to
the native fallback, not ordinary browsing of intranet sites.

## Retained browser compatibility behavior

The owner chose to retain these behaviors:

- Tracking prevention is disabled for website data stores to support signed-in
  third-party embeds. This weakens protection against cross-site tracking;
  profile separation still uses distinct website data stores.
- Opening a local HTML file grants WebKit read access to its containing
  directory so sibling images, styles, and media work. Treat local HTML as
  trusted: a malicious file may access neighboring files in that directory.
The native application is not App Sandbox confined, and its ATS configuration
permits arbitrary loads. Those are broad platform privileges, not evidence
that a particular remote exploit succeeds. Changing them requires checking
browsing, runtime, and mod capability requirements.

## Form recovery and script worlds

Automatic form-field capture and restoration are disabled. Scroll restoration
saves only a position and timestamp. On each origin visited, Bowser deletes its
old `bowser-preserve:*` snapshots from local/session storage without replaying
values. Snapshots on origins not revisited remain until their website data is
cleared or that origin is visited.

Mod JavaScript defaults to an isolated content world. Native code retains site
payloads and selects only matching loaded frame hosts, with an execution-time
URL recheck for navigation races. Page globals require an explicit page-world
capability. Shared DOM access remains available and DOM data remains visible
to the website; isolated JavaScript is not private DOM storage.

## Planned platform hardening

`bowser-browser-hxc1` tracks the separately approved plan: threat model and
compatibility inventory first, then Keychain credentials, authenticated IPC,
sandbox/capability boundaries, and narrower ATS exceptions. Integrated signed
release, notarization, and rollback checks depend on those workstreams. These
platform changes are planned, not implemented by the immediate security fixes.
