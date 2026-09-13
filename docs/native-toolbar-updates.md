# Live native rendering updates

Bowser can replace two signed rendering modules while keeping its native host
and WebKit views alive:

- **CommandToolbar** renders the command/navigation cluster beside the traffic lights.
- **SurfaceRenderer** renders Deck Tabs, mod sidebars/toolbars, floating surfaces,
  and settings view trees, plus tab drag gestures and their presentation. The built-in fallback uses the same rendering source.

The executable owns windows, WebKit, profiles, IPC and validated tab operations. The surface module owns drag views,
gesture decisions, reorder targeting, close cues and dust animations. `BowserSurfaceKit`, a library loaded with the host, owns surface models,
form submissions, cursor/drag state, the image cache and native editor instances. Renderer changes
reuse those objects. Changes to this state library or other host code require a
normal host update.

## Install and update

`bin/install` embeds both modules and the state library in the staged browser,
and publishes signed module generations independently of host/backend activation.
It prefers an available Developer ID certificate; `BOWSER_SIGN_IDENTITY=-` builds
an ad-hoc host that accepts bundled modules but rejects external live modules.

Installing the expanded host requires a normal quit/reopen. After that,
`bin/install --native-only` builds and publishes both renderers without restarting
or rebuilding the browser executable. It also builds their state-library dependency;
if that library changed, the running host rejects the incompatible surface module
and continues using its current renderer. Use a normal install for that change.
`--debug` selects debug host/state-library builds; otherwise installation uses release.
The surface module must match the running state library exactly.

Publishing is not an activation acknowledgement. A compatible signed host polls
every two seconds, loads candidates on a worker, and swaps them when interactions
permit. An interaction lease spans mouse-down through release or the final drag-session
callback, so a drag retains its original implementation. Rejections are logged as `Native module update rejected`. Saved site apps
bundle their matching state library and use the built-in surface renderer.

Renderer sources are `shell/NativeModules/CommandToolbar/Toolbar.swift` and
`shell/Sources/Bowser/Surface{Renderer,Forms,Composition,TextEditor,TabDrag}.swift` and `TabDustEffect.swift`.
The surface bundle's C entry points are in `shell/NativeModules/Surfaces/Exports.swift`.
The stable contracts live in `shell/SurfaceKit/`.

## Admission and lifetime

A live module must have a valid Developer ID signature from the host's Team ID,
the expected module identifier (`com.foxwiseai.bowser.command-toolbar` or
`com.foxwiseai.bowser.surfaces`), host ABI 1, state schema 1 and backend protocol 1.
The surface module additionally pins the Mach-O UUID of the already mapped state
library. This identity check happens before `dlopen`; comparing against a newly
replaced file on disk would be incorrect.

Modules may depend on system libraries/frameworks/Swift runtime. SurfaceRenderer
may also link the already loaded `@rpath/libBowserSurfaceKit.dylib`. It cannot supply
its own copy or another writable-path dependency. Packages are limited to 16 MiB
and 32 entries. Wrong signatures, metadata, identities, symlinks and unsupported
Mach-O dependencies fail closed. Library validation remains enabled.

The publisher atomically selects an immutable generation. The loader verifies,
copies to a private directory, makes the copy read-only, verifies again and loads
on a worker. Builds have unique Swift module names. These are first-party native
components with full process privileges; ModSmith and websites cannot publish them.

UI creation and attachment run on the main actor. Mouse buttons, tab dragging,
menus, sheets/popovers, field-editor typing, marked-text composition, live resize
and fullscreen transitions defer replacement. Candidate callbacks are ignored
until commit; retired-generation callbacks are ignored afterward. Native editor
mounts cannot move a live editor until their generation becomes authoritative.
The same NSTextView, delegate, undo manager, text storage and selection then attach to the new
renderer. Form values, validation errors and pending request IDs remain host-owned.

Candidate creation exceeding 16 ms is rejected; this detects a breach after it
occurs, not preemptive isolation. The old renderer remains until creation and
initial state validation succeed. Invalid subsequent state restores the fallback.
Retired SwiftUI views can survive briefly; further admission waits for their weak
references to clear. Each module family allows at most 32 attempted paths and
64 MiB of admitted bundle bytes per process. Mappings stay until exit; no `dlclose`
or arbitrary Swift unloading is attempted. In-process rollback cannot contain a
crash in signed native code.

## Verification

`bin/check-native-toolbar` and `bin/check-native-surfaces`, with
`BOWSER_SIGN_IDENTITY='Developer ID Application: …'`, build real module generations
and isolated hardened-runtime test apps. They use nonpersistent WebKit stores,
AppKit input events and playing video without touching installed browser data.
The surface check verifies native editor identity, unsaved text, selection, focus,
typing/undo after replacement, drag deferral and a Deck Tabs action.

For native tests, set `BOWSER_TEST_TOOLBAR`, `BOWSER_TEST_SURFACES` and
`BOWSER_TEST_SURFACES_SECOND` to the corresponding signed bundles before running
`swift test` in `shell/`. Signing-specific tests skip when fixtures are absent.
Recorded runs live under `tests/native-toolbar/results/` and
`tests/native-surfaces/results/`.

Notarization/quarantine qualification, audible/DRM/live streams, physical input
latency and the 100-build/24-hour memory soak remain tracked in
`bowser-browser-29v.6` and `bowser-browser-u6x9.3`. Signed local checks do not establish
those broader gates. See ADR 0014.
