# Native resource ownership

The native process owns windows, webviews and editors for their complete lifetime.
Elixir controllers own feature decisions; native components own immediate input
and rendering. A controller reconnect reconciles existing resources rather than
recreating webviews. Profile membership remains enforced by the native owner.

`hello.resources` and `resource_snapshot` expose protocol version 1, native launch
session ID, next command sequence, topology revision, and windows with stable IDs,
profile IDs, ordered tab IDs and active tab. No cookie or document data is included.

`resource_command` contains `version`, `session`, `sequence`, and `command`.
The command names its observed `revision`, `window`, `profile`, `tab`, and `action`.
Actions are `activate`, `move` (with `target` and `after`), and `close`.
`resource_result` returns an acknowledgement plus the current resource snapshot.
A stale topology is rejected before applying an operation. A failed operation
still consumes its sequence; retrying uses the original envelope.

Sequences are monotonic within a native launch. The owner retains the latest 128
acknowledgements and rejects older sequences even after their acknowledgement was
evicted. Identical retries return the original result; conflicting reuse fails.
This prevents duplicate effects while the native process lives. After reconnect,
controllers obtain a fresh snapshot and reconcile uncertain operations rather
than manufacturing new sequence numbers for destructive retries. Commands queued
from a disconnected socket cannot act through a subsequent connection.

These are internal controller contracts, not new ModSmith capabilities. Existing
native call sites remain until their controller is extracted. Creating native
objects, calling AppKit and fulfilling platform delegate contracts remain native;
choosing feature behavior belongs in the replaceable controller layer.

## Mod state upgrades

Mods declare `state_version/0` (default 0), `migrate_state(old_version, state)`
returning `{:ok, state}` or `{:error, reason}`, and `validate_state(state)` returning
`:ok` or `{:error, reason}`. Defaults retain state only for an unchanged version.
Migration and validation run in a disposable BEAM with the candidate code, before
any candidate bytecode enters the browser brain. Callbacks must be pure data
transformations; browser services are not started there. Accepted Elixir remains
fully privileged: this compiler peer is not an operating-system sandbox.

The loader suspends affected mod event loops, snapshots their data-only state,
prepares and validates migrations, installs state while still suspended, and
atomically loads the candidate modules. Failed compilation or preparation never
changes the live code. Failed activation restores old state before resuming.
Mailboxes retain queued events. Successful upgrades emit `mod_reloaded` for UI
reassertion; `init_mod/1` does not run again. Runtime handles in mod state require
an explicit redesign of that mod's state ownership before it can use this path.
Whole-brain checkpoint handoff remains a separate upgrade mechanism.

## Tab controller

`ResourceController` is a supervised, reconstructible Elixir service. Tab order,
new-tab placement, activation/cycling and close-successor selection are pure
policy functions there. The native process allocates webviews synchronously when
WebKit requires one, then asks the controller to arrange/activate them. The first
tab of a new window is bootstrap resource creation. Saved site apps retain their
single-app native behavior.

After `resource_ready`, native tab gestures and commands enqueue intents (up to
256) instead of making policy decisions locally. One head intent is issued at a
time with a fresh topology snapshot. `resource_decision` must reference that
request. A stale topology retries with a fresh snapshot; a completed request ID
cannot be applied again. Pending intents stay native through controller death,
reconnection and whole-brain replacement. A one-second readiness heartbeat recovers
a controller restart without requiring a new socket connection. Browser-internal
resource intents go only to the controller, not to mod event subscribers.

The controller contains no authoritative resource state, so it reconstructs from
native snapshots rather than joining the whole-brain checkpoint's state schema.
Native drag feedback and text input continue while it is disconnected; queued tab
operations resume when it returns. The owner validates window/profile membership
and complete tab-order permutations before applying decisions to existing views.

`bin/check-resource-controller` runs actual Elixir code replacement and controller
process reconnection against an isolated native browser window. It checks changed
policy behavior, single application of a queued close, retained webview/document,
editor draft/selection/focus/undo and advancing video. This is synthetic input and
local media, not a physical-input or DRM qualification.

## Navigation and downloads

Elixir publishes ordered navigation rules with required/forbidden modifier names
and a native tab action. The native owner validates the complete rule set before
replacing its cached policy, then answers WebKit synchronously. External-scheme
approval, WebKit-required popup allocation and non-displayable-response handling
remain native enforcement. Policy refresh does not replace any webview.

`NativeDownloads` owns WKDownload delegates and pending destination callbacks
independently of source tabs. Destination naming is decided by the Elixir
controller from a native download snapshot. The native owner enforces profile
identity, basename-only filenames, collision avoidance (including reserved paths)
and single completion of each callback. Once started, a transfer continues
without the controller. A source tab closing does not retire its download.

The native integration check also streams a real 1 MiB WebKit download from a
loopback fixture, closes its source tab and restarts the controller before
completion. Files are written only to the temporary fixture directory.

The remaining restart boundary is changes to native object storage/lifetime,
platform delegate integration, the shared SurfaceKit contract, IPC transport and
native UI not extracted into signed modules. Elixir policy and existing native
module behavior can update independently; this does not replace WebKit itself.
