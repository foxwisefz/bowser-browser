# Controller replacement with a persistent native host

This experiment retains the real Bowser `EngineView` and `BrainBridge` while
replacing external controller processes. It uses a disposable app bundle,
nonpersistent WebKit storage, an isolated socket and a generated local video.
It does not install anything or connect to the owner's browser/backend.

Build with `bin/experiment-controller-handoff`, then open the app path it prints.
The app briefly takes foreground focus and tests both native window fullscreen
and HTML video fullscreen. It exits after writing `result.json`, or `failure.txt`
if setup fails, in the printed temporary directory. `result.json.passed` is the
experiment result; building the fixture alone does not run the assertions.
Requires the installed Swift toolchain, Python 3 and ffmpeg.

## Observed run — 2026-09-08

The committed `result.json` records one initial controller connection followed by
10 replacements: five in native fullscreen and five in HTML video fullscreen.
All assertions passed. Replacement latency, measured from requesting termination
of the previous controller through acknowledgment of a command from its
replacement, was **66.9–81.3 ms**. This includes controller startup and a 10 ms
polling interval; it is not a measurement of a visible blackout.

The same native window number, WKWebView object, page token, JavaScript closure
state and video element survived. Playback time and closure counters advanced.
There were no pause, waiting, seeking, emptied or ended events within the measured
handoff intervals. Frame callbacks delivered 32–34 frames in approximately 1.1
seconds at a 30 fps source rate, with a largest observed callback gap of 51 ms.
The native window remained key during the native-fullscreen phase; the active
HTML-fullscreen presentation retained its key window during its phase.

An earlier XCTest-only harness could not obtain foreground focus and produced
throttled frame callbacks. Its measurements were rejected. The standalone app
uses the same production source files, with only a separate experiment entry
point and resource bundle accessor; production code is unchanged.

## What this establishes

The existing public WKWebView integration and Bowser bridge can keep a playing
page alive across replacement of a controller client. Native and HTML fullscreen
can survive that operation without serialization or page reconstruction.

This is **not** a completed automatic updater. The controller clients are small
Python processes that adopt the live webview from the existing protocol hello and
apply a generation-specific command. The experiment does not migrate a full BEAM
backend, preserve queued controller events, validate rollback or protocol-version
compatibility, or replace the native host/WebKit code. It uses muted local video:
audible continuity, DRM, streaming/network changes and the real X bookmarks feed
are not verified. The 51 ms callback gap is an observation, not a guarantee for
other workloads or machines.

The next production-relevant experiment is full backend replacement with live
host adoption, event buffering, stale-command rejection and rollback, while
preserving profile/tab ownership and preventing session reconstruction.
