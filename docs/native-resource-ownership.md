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
