# 0013 — Supervise icon work outside the browser process

Status: accepted (2026-09-07).

An icon operation inherited Swift MainActor isolation, ran on a worker thread,
and terminated the entire browser through an executor assertion. Moving work
off the UI thread did not isolate failure. A native launch test that never
loaded an icon missed the bug.

The shell discovers page-declared artwork through WebKit and supplies candidates
with a webview, URL, profile, and navigation generation. IconJobs in Elixir owns
candidate ranking, bounded concurrency, public-download fallback, cache keys,
timeouts, retries, and the decision to publish an update. Saved apps have their
own target namespace through the main-browser hub.

Pixel normalization and ICNS generation live in BowserIconWorker, a disposable
OS process launched by a supervised Elixir task. IconRendering is a separate
Swift target that is **not a dependency of the Bowser executable**. The browser
only displays the final PNG and copies a prepared ICNS into a native app bundle.
Do not move native rendering into a NIF: that would move the crash into BEAM.

A failed worker leaves the existing icon untouched. Late results cannot replace
an icon from another navigation. Reconnecting the brain requests fresh icon
candidates without reloading the page.

`bin/install` must run `bin/check-icon-isolation` before replacing the installed
app. The check kills the first renderer in an isolated signed-app fixture,
requires Elixir to retry successfully with the same browser/coordinator alive,
tests worker timeout and stale results, and checks that IconRendering is absent
from the browser's symbols. This is a fault-isolation gate, not automatic rollout
rollback or a guarantee against unrelated shell crashes.
