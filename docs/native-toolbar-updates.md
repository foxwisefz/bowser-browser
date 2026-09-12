# Live command-toolbar updates

The command/navigation cluster next to the traffic lights now has a versioned
native module boundary. The module renders the existing SwiftUI ⌘K keycap,
back/forward/reload buttons, profile tint, theme and mod buttons. The host owns
the windows, WKWebViews, profiles, state snapshots and action dispatch. Module
callbacks carry a generation token; retired generations cannot navigate or
issue mod commands. Other native views, including Deck Tabs drag handling and
sidebar rendering, remain in the executable.

## Install and update

`bin/install` builds a signed toolbar bundle into the browser and publishes it
independently alongside the normal pending host/backend update. It selects an
available Developer ID Application certificate unless `BOWSER_SIGN_IDENTITY`
is explicitly set. `BOWSER_SIGN_IDENTITY=-` produces an ad-hoc development host:
it may use its bundled toolbar but rejects external live modules.

The first installation of this host requires a normal quit/reopen. Once it is
running, use `bin/install --native-only` for changes confined to
`shell/NativeModules/CommandToolbar/Toolbar.swift`. This builds and publishes
only the module. It does not rebuild the executable or restart the browser.
Publishing is not an activation acknowledgement: a compatible signed running
host checks the pointer every two seconds, loads it on a worker, and installs
it when interactions permit. Rejections are logged as `Native toolbar update
rejected`. Host ABI changes and changes elsewhere in the executable still
require a normal host update. Saved apps currently do not show this cluster.

## Admission and lifetime

Only a Developer ID module from the running host's Team ID, with identifier
`com.foxwiseai.bowser.command-toolbar`, is admitted live. Its signed Info.plist
pins host ABI 1, toolbar state schema 1 and backend protocol 1. The executable
must be arm64, with only system framework/library/Swift-runtime dependencies.
Unknown metadata, invalid signatures, wrong teams, symlinks and oversized
packages reject before loading. No library-validation exception is added.

The publisher atomically selects an immutable generation. The host copies it
into a private per-process directory, makes files read-only and verifies the
copy before `dlopen`. Each build has a unique Swift module name. These are
first-party native components with full process privileges, not a way for
ModSmith or website content to supply native libraries. Same-user processes
already have the documented desktop trust relationship; filesystem permissions
are not a sandbox against that user.

All UI work remains on the main actor. The old toolbar stays authoritative
while the worker loads. Mouse buttons, Deck Tabs dragging, menus, sheets, live
resize, marked-text composition and fullscreen transitions defer admission.
The toolbar has no independent text/editor state: the host supplies a bounded
JSON snapshot, including reveal state, profile tint, theme and buttons. Prepared
views cannot access page references. Preparation exceeding 16 ms is rejected;
that detects a budget breach after it occurs, rather than preempting native code.
The old view remains until creation and state validation succeed. Callbacks from
candidates are ignored until commit. Invalid subsequent state restores fallback
controls. SwiftUI render transactions may briefly retain retired views; further
admission waits for those views to disappear.

Library mappings remain until process exit. Admission stops at 32 attempted
paths or 64 MiB of admitted bundle bytes. These are bounded admission policies, not measured physical
memory guarantees. Bad native code can still crash the process; in-process
rollback is not crash isolation. No arbitrary Swift unloading is attempted.

## Verification

`BOWSER_TEST_TOOLBAR=/absolute/path/CommandToolbar.bundle swift test` in `shell/`
runs real signed-module admission and lifecycle tests alongside the native
suite. Without that fixture, signing-specific tests skip explicitly.

`BOWSER_SIGN_IDENTITY='Developer ID Application: …' bin/check-native-toolbar`
builds two real toolbar generations and a hardened-runtime host. It checks
Developer ID admission with library validation enabled, actual AppKit mouse
and key event dispatch, retained unsent text, page identity and advancing video.
It uses an isolated nonpersistent WebKit store and never touches installed
browser state. The recorded run is in
`tests/native-toolbar/results/signed-replacement.json`.

This delivers the command-toolbar boundary, not arbitrary native replacement.
Notarization/quarantine qualification, audible/DRM/live-stream coverage, physical
input latency and the 100-distinct-build/24-hour memory soak remain in
`bowser-browser-29v.6` and `bowser-browser-u6x9.3`. Those gates are not established
by the signed local test. The broader proposed design is ADR 0014.
