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
