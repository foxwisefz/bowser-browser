# Native module replacement experiment

Run `experiments/native-modules/run` from a logged-in macOS desktop with Xcode
and ffmpeg. It builds an isolated app and four Swift dylibs under a fresh
`/tmp/bowser-native-modules.*` directory, generates a local video, opens the
fixture, runs assertions, and exits. No installed Bowser binary, profile,
BEAM process, or session store is accessed. Swift and ffmpeg are experiment
build tools; this adds no shipped helper runtime.

## Boundary under test

The stable host owns NSApplication, NSWindow, WKWebView, and the loaded page.
Versioned Swift modules own a small AppKit view and its button behavior. V1
increments by one; V2 changes the label/color and increments by two. A C ABI
exports version/create/step/read/destroy functions. Only scalars, a C callback,
and an explicitly retained Objective-C view pointer cross the boundary. All
calls and authority transfers happen on the main actor.

Before replacement, the host reads the old counter, checks ABI compatibility,
and prepares a candidate view. Once preparation succeeds it switches the
active generation and view, then destroys the old view. Deliberately delayed
callbacks from retired generations are rejected. Dylib handles stay mapped;
this is object retirement, **not safe unloading of arbitrary Swift code**.
Each actual build must have a unique Swift module name and immutable path.

V2 and the rejection fixtures are first loaded while the video is fullscreen.
Twelve replacements alternate two compiled implementations; twenty-four
candidate attempts test incompatible ABI and failed preparation. Assertions
cover changed native button behavior, preserved counter, stale callbacks,
released retired views, page/player/window identity, JS closure activity,
scroll, fullscreen focus, advancing playback, interruption events, and video
frame-callback gaps below 250 ms. `loadMS` measures loading three candidate
libraries. `swapMS` measures view/authority transfer and old-view destruction,
excluding loading and candidate preparation; it is not an end-to-end update
latency claim.

## What this does not prove

This does not replace the main executable, AppKit, or WebKit, nor migrate
arbitrary Swift object graphs. It does not hot-patch existing methods. Code in
the stable owner still needs an ordinary restart to change. Module crashes or
memory corruption can kill the host; rejection tests cover explicit errors,
not crash isolation or recovery after corrupting shared state. State migration
here is one integer, not the entire browser model. There is no production
update manifest, event journal, signing admission policy, resource migration,
or BEAM/module compatibility protocol in this fixture.

Retaining old library mappings trades restart avoidance for growth in mapped
code/metadata as distinct builds accumulate. This run alternates two versions;
it does not establish a bound for months of updates. The video is local and
muted, not live X, DRM, a call, or an audible media continuity test.

The fixture is ad hoc signed. A shipped host must validate its own signed
modules before loading and preserve hardened-runtime library validation.
Apple documents that enabled library validation accepts Apple code or code
signed by the same Team ID as the host:
[Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html).
Developer-ID signing/notarization under Bowser's actual distribution settings
remains a separate production gate.

## Product direction

Keep common UI changes in live surface trees. For genuinely new native
behavior, extract a deliberately narrow module API around a small stable
window/page owner. The experiment only establishes feasibility at that
boundary; it is not installed as Bowser's updater.

## Recorded results (2026-09-09)

`results/fullscreen-scroll.json` records a passing run: 12 swaps, 24 rejected
candidates, counter 18, 11 stale events rejected, and 12 old views released.
The same window/page/player stayed fullscreen and playing. The page scrolled
to 120 before fullscreen and returned to 120 after exit. There were no media
interruption events. Individual view transfers were under 1 ms; loading three
candidate libraries took 1.317 seconds. Loading currently runs on the main
thread, so native interaction can stall even while WebKit media keeps playing.
Moving or preparing this work safely is a separate engineering requirement.

`results/fullscreen.json` is the earlier passing continuity run.
`results/focus-failure.json` preserves an intervening failure of the combined
window/page/focus assertion. Its cause was not established; it may be fixture,
desktop interference, or a lifecycle issue. A repeat with expanded diagnostics
passed without changing the replacement logic. Do not describe these results
as reliable across all runs. The runner also now explicitly starts playback
instead of relying on autoplay after one startup timeout.

Production admission, cold-load responsiveness, and the intermittent focus
failure are tracked in **bowser-browser-kgu9**. The live UI expansion is
**bowser-browser-6k1a**; this isolated experiment is **bowser-browser-d4lb**.
