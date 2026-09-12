# Native module admission around a stable page owner

Status: command-toolbar boundary implemented; broader qualification remains open.
Date: 2026-09-11. Bead: bowser-browser-kgu9; parent: bowser-browser-29v.

## Boundary and guarantees

Keep NSApplication, NSWindow, WKWebView, website data stores, delegates that
control navigation/media, the responder chain, native fullscreen transitions,
and socket/event routing in a small stable owner. Existing page objects and
WebKit processes continue running across a controller update. Move replaceable
native toolbar/panel behavior into versioned modules only after extracting this
boundary from AppDelegate, BrowserWindowController, EngineView, BrainBridge,
SurfaceHost, and the SwiftUI hosting views. The command-toolbar cluster has been
extracted; other shell views remain in the host. See
[current implementation](../../docs/native-toolbar-updates.md). The backend
relay is a precedent for independently replaceable components.

The stable owner holds all page/window references. Modules get opaque handles
with owner-provided operations, not raw WKWebView pointers or delegate authority.
No module may reparent a page, recreate its configuration, replace its data
store, navigate to reconstruct state, or toggle fullscreen during admission.
Core navigation remains built in. User mods remain BEAM processes or declarative
surface trees; loading arbitrary user Swift libraries is outside this design.

Only module-owned behavior changes live. A security fix in the stable owner,
WebKit, AppKit or the OS requires replacing that component and may require a
restart. Keep those updates visible as pending; never report an old mapped host
as patched merely because its on-disk bundle was replaced. The engine build UUID
handshake identifies that distinction. This design cannot promise arbitrary
native-code replacement while preserving an opaque WebKit heap.

## Admission record and signing

An authenticated release manifest names the module's build UUID, content hash,
unique Swift module name, entry-point ABI, state schema accepted/emitted,
minimum/maximum host ABI, required owner capabilities, BEAM protocol and
checkpoint schema, resource hashes, dependency identities, and rollback target.
Check every compatibility dimension before quiescing. Unknown capabilities,
versions, dependency paths, or migration directions reject the candidate.

Stage into a generation directory under the owner-controlled updates area.
Reject symlinks, path escapes and writable/shared dependency locations. Validate
the complete signed bundle and manifest, then publish the immutable generation
by atomic rename. Retain the exact validated artifact through loading; checking
one path and loading a subsequently substituted file is unacceptable. No
network/FUSE location or mutable development checkout is admitted. Content hashes
identify the release but do not substitute for signature authentication.

Use Developer ID signing with hardened runtime on the actual distributed host
and modules. Pin the expected Team ID and module identifier/designated
requirement with Security framework checks; verify dependencies and resource
seals, not merely the presence of a signature. Keep library validation enabled.
Apple's library validation permits Apple code and code signed with the host's
Team ID; the host also needs its narrower manifest/identifier checks.
[Apple library validation documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation).

Perform static validity checks before executing candidate code. Apple's static
validation guidance explicitly calls out changes to files after validation;
immutable staging is therefore part of admission, not just caching.
[SecStaticCodeCheckValidity](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:)).
Hardened runtime is also required for notarization.
[Apple hardened runtime guidance](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime).

Current evidence: a Foxwise Developer ID identity is available. The integrated
command-toolbar check passed in a Developer ID signed hardened-runtime host
with library validation enabled on 2026-09-13. See
`tests/native-toolbar/results/signed-replacement.json`. Notarization and
quarantine qualification remain separate gates; local signing does not prove them.

## ABI, preparation and state

Use a narrow versioned C function table with fixed-width scalars, length-delimited
byte buffers and opaque owner handles. Define allocator/free responsibility for
every buffer. Do not pass Swift objects, closures, generic values or enum layouts
across the ABI. A module can return one retained NSView for its own content with
an explicit release function; the host controls its placement and lifetime.
Module callbacks are nonisolated C thunks that enqueue onto the owning actor.
Every callback carries its generation and sequence number.

Keep persistent UI state in an explicit, bounded data schema: selected tool,
expanded panel state, draft text, selection ranges, semantic focus target and
pending operation IDs. The host owns focus restoration and maps semantic targets
to new controls. During marked-text composition, menus, drag/drop, modal sheets,
fullscreen transitions, or unresolved delegate callbacks, defer the switch.
Do not serialize pointers, subscriptions, timers, tasks or SwiftUI object graphs.
Resource handles are reissued by the owner after migration. Migration must be
pure and deterministic; preparation cannot issue external commands or mutate
the live browser. SwiftUI modules need tests that prove no old environment,
ObservableObject, closure or hosting-view reference survives retirement.

Download, hash/signature validation and data migration run off the main thread.
AppKit view preparation and authority transfer run on the main actor. `dlopen`
executes library initializers and registers Swift metadata: prechecking a file
in a helper does not make loading it in the browser free or safe. Require trivial
initializers and measure cold loading in the real host. Reject a build from live
admission if its measured main-thread work exceeds the responsiveness budget;
schedule it for ordinary activation. Do not blindly move AppKit/SwiftUI
initializers onto a background queue.

## Event and authority protocol

The owner numbers native events monotonically and owns the bounded journal.
Each module generation has one authority token. Commands include that token and
an operation ID; stale generations cannot issue commands even if their callbacks
arrive late. Synchronous WebKit delegate decisions remain in the stable owner.

Admission phases are validate, prepare, quiesce, migrate, commit, drain, retire.
Before quiescence, old code serves all events. Establish a sequence barrier and
wait for its tracked commands and callbacks to complete. Journal later events
without stopping WebKit or media. Freeze module mutation, snapshot its bounded
state, migrate, and prepare the new view offscreen. Validate the candidate's
state and resource plan. One main-actor transaction changes the authority token,
view and semantic focus, then replays each buffered event exactly once to the
new generation. Replay and new arrivals share a single ordered queue. Overflow,
timeout or a pending non-transferable operation before commit abandons the
candidate and resumes the old generation with the same journal.

Coordinate native and BEAM changes through a manifest compatibility envelope.
Prefer separate updates where either backend is compatible with either module.
If a joint update is unavoidable, both candidates must be prepared and both
barriers acknowledged before changing authority. The stable owner records the
committed pair atomically. Neither side independently assumes the other switched.
Post-commit failure must never replay commands into the retired pair.

## Retirement and failure

After draining pre-barrier callbacks, cancel and acknowledge all module-owned
subscriptions, observers, timers and tasks. Remove its view, sever callback
contexts, release hosting objects, and assert a zero live-object count using
weak references and explicit counters. Late callbacks are discarded by token.
Keep dylib mappings loaded for process lifetime: arbitrary Swift unloading is
not supported by this design. Unique build names avoid runtime name collisions.

A failed validation, preparation or migration leaves the old generation active.
A native crash or memory corruption after `dlopen` can kill the stable host;
there is no in-process crash isolation. A separate probe process may catch
obvious failures but cannot prove safety in the real host. After a crash,
quarantine the failing build, select the previous admitted pair on next launch,
and use existing cold-session recovery. Do not claim that recovery preserves
opaque page state. Security revocations override rollback eligibility.

## Evidence and production gates

The existing isolated experiment retained one window/page/player over 12 swaps
between two builds, rejected 24 candidates, and rejected 11 stale callbacks.
It also archived an unexplained focus failure. Loading three libraries cost
1.317 seconds on the main thread. These are feasibility results, not production
acceptance. See [experiment results](../../experiments/native-modules/README.md).

Before enabling admission, require:

- A real Bowser toolbar/panel and a SwiftUI module across distinct builds, with
  working interactions before and after each transfer; no fixture-only claims.
- Real Developer ID/hardened-runtime/quarantined installs, including tampered
  resources, wrong-team libraries, stale manifests, symlink substitution,
  dependency replacement and incompatible schemas rejected before authority.
- Fault injection at every phase, ordered concurrent event traffic, journal
  overflow, migration failure and delayed callbacks; no lost/duplicate actions.
- Focus diagnostics covering window number, key/main window, first responder,
  semantic control, page active element, selection and IME state; repeated
  fullscreen entry/exit. Explain and reproduce the archived failure first.
- Audible playback, live streams, DRM where available, and live X virtualized
  feed tests. Preserve exact page/player identity, bookmark/tweet and feed
  position, volume/time, fullscreen, profile, focus and transient page state.
  Measure audible gaps and video frame callbacks; a screenshot or URL match is
  insufficient. Target under 250 ms media gaps and under 1 s total interruption,
  while normal main-thread interaction meets a separately measured frame budget.
- A 24-hour soak through at least 100 genuinely distinct builds, measuring RSS,
  physical footprint, dirty memory, mapped code/metadata and live object counts
  after each retirement. Compare with an idle control process. Proposed initial
  admission ceiling: 128 MiB incremental physical footprint or 100 generations,
  whichever comes first; calibrate from results before shipping. At the ceiling,
  stop admitting modules and preserve the session pending normal activation.

Passing these gates enables only the extracted module boundary. Whole-host and
WebKit upgrade continuity remains the broader open goal of bowser-browser-29v.
