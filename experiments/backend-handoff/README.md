# Full backend handoff experiment

Build with `bin/experiment-backend-handoff [video-tweet-URL]`, then open the printed
app path. Without a URL it uses a generated local video. The app takes foreground
focus and enters HTML video fullscreen. All sockets, profile stores, backend data
and logs live in the printed `/tmp/bowser-handoff.*` directory. It does not install
or restart the owner's browser. Requires Swift, Elixir, Python 3 and ffmpeg.

The fixture compiles the production native sources with a separate entry point.
It launches the complete BEAM application supervision tree, with separate runtime
homes. The 21 production children start; automatic host spawning and checkout
watchers are disabled, and the XServer listener does not open the shared 4808 port.
User mod directories are empty. A test observer is added to acknowledge durable
receipt of events. This is not a simulation of the BEAM application.

A prototype relay stays connected to the native host while backends change. It
journals host events in SQLite (WAL, synchronous FULL), gates admission, sends the
latest live tab/profile snapshot before replay, and translates request IDs so a
late old-generation reply cannot be mistaken for a new request. Backend readiness
requires live-session adoption and a successful page command, rather than just a
running process. A candidate is warmed while the old backend remains active.

The test rejects a protocol-incompatible candidate before granting authority,
replaces a healthy backend, then deliberately crashes another candidate with exit
86 after attach. The previous still-running backend reconnects and resumes. Events
continue to be generated during these transitions. The host compares the number
generated with the relay journal and durable subscriber receipts.

## Validated local run — 2026-09-08

`local-result.json` contains the final foreground run:

- Full backend handoff: 41.3 ms after candidate warmup.
- Failed-candidate rollback: 392.2 ms total control gap, including detection.
- 184 generated probe events, 184 captured, 184 distinct durable receipts; zero
  duplicate probe deliveries observed in this run.
- One deliberately delayed old-generation response rejected.
- Two profile identities and the active tab adopted; Session.restore remained nil.
- Same native window, WKWebView, page token and video element; HTML fullscreen and
  focus survived. No pause/waiting/seeking/emptied/ended events during measurement.
- Maximum observed video-frame callback gap: 51 ms.

`result.json.passed` in a run directory is the combined assertion result; build
success alone is not a passing test. Setup errors appear in `failure.txt` or
`backend-failure.txt`. Backends are cleaned up when the relay completes or receives
SIGTERM; failed candidates cannot terminate the native host.

## Validated live X run — 2026-09-08

Requested URL: https://x.com/ycombinator/status/2096970626036855197/video/1

`x-result.json` records the real X page and player in the isolated app. All
assertions passed:

- Healthy full backend handoff: 41.2 ms after candidate warmup.
- Deliberate candidate crash and rollback: 386.9 ms total control gap.
- 185 generated probes, 185 captured and 185 unique durable receipts; no duplicate
  probe delivery observed. All 194 journal events were acknowledged.
- One stale old-generation response rejected; incompatible candidate denied
  authority; the candidate admitted for the failure test exited with code 86.
- All 21 production supervision-tree children present; active tab and both profile
  identities adopted without Session reconstruction.
- Same native window, WKWebView, X page token and video element. HTML fullscreen,
  focus and the page URL remained unchanged. Playback advanced from 1.79 to 6.27 s.
- No pause/waiting/seeking/emptied/ended events during measurement. 108 video frame
  callbacks; maximum observed callback gap 55 ms.

The first CUA-launched X fixture timed out before its document loaded. The owner
then explicitly authorized a read-only check of the existing X tab, which showed
the correct video and a successful fresh X request. A subsequent explicitly
approved normal LaunchServices launch of a fresh isolated fixture completed the
live test. The precise cause of the earlier launch/network difference was not
established. No firewall/security settings or existing-tab playback were changed.

This is the supplied tweet permalink, not a logged-in bookmarks-feed traversal.
Scroll position was unchanged at zero; a nonzero virtualized-feed anchor was not
separately exercised. The same live page/heap was retained, not serialized.

## Limits

This relay is experiment code, not an installed automatic updater. The backend
application is real, but it runs without the owner's mods and external services.
Receipt replay is **at least once**: the observer fsyncs before acknowledgment,
but arbitrary mods and external side effects do not share that transaction.
A crash after processing and before acknowledgment can require deduplication.

The journal preserves events across backend replacement, not native-host or relay
crashes. Its unbounded growth, disk failures, persistent recovery, schema migration,
controller-local state migration, and complete production protocol coverage still
need engineering. This fixture verifies session adoption and marker receipts; it
does not prove migration of every in-memory GenServer or mod state.

Media is muted. Audible continuity, DRM and network disruption are not verified.
The 51 ms callback gap is observed telemetry, not an audible or optical measurement
or a universal performance guarantee. The native host and WebKit code are retained.
