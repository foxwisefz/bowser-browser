# ADR 0011 — Mods as generated native declarations (the iOS path)

**Status:** Accepted (direction), 2026-08-22
**Epic:** bowser-browser-3fo

## Context

Bowser's mods on macOS are Elixir OTP processes and injected CSS/JS: they
reshape someone else's webpage, hot-reloaded live by the brain. The owner
wants this on iOS — but not "a shitty web browser experience while apps sit
there." The goal is **real, editable (or new-able) native apps** — e.g. a
custom X client you can restyle or spin fresh on demand.

iOS forbids exactly what makes the macOS mod system work:

- **No downloading executable native code** (App Store 2.5.2). Hot-reloading
  `.ex` files — the soul of the system — is banned, and the BEAM's JIT
  can't run (no executable memory).
- **No custom browser engine** (outside the EU DMA carve-out).

## Decision

On iOS, **a mod is a native-screen DECLARATION, not injected CSS.** The
unit of dynamism inverts: distribution is the app, dynamism is data.

- **One host app** = a Server-Driven-UI runtime shipping a native component
  vocabulary (timeline list, tweet card, media viewer, compose). Real
  UIKit/SwiftUI, real scroll and gestures — never a webview.
- **Mods = declarations** — trees describing screens, bindings, interactions
  — generated and hot-swapped by the brain. New app = new declaration; edit
  = edit the declaration. Same mod loop, native output.
- **The brain is the data adapter** — it extracts structured data from the
  owner's logged-in web sessions (X has no usable API) and feeds the
  runtime.

This threads the iOS rules: a runtime rendering downloaded **data** is how
Airbnb/Spotify change native screens without App Store updates. Declarations
and data are data, not code. Compliant, native-feeling, infinitely editable.

## The real risk is X, not iOS

Native rendering needs structured data. X banned third-party clients (2023)
and its API is hostile ($100+/mo, neutered), so the only source is the brain
scraping x.com through the owner's session — fragile, and X will fight it.
**The iOS/native/generated/editable side is very doable; the fragile part is
X making itself hostile.** Any less-hostile service is dramatically easier;
the same runtime serves them all, X being the hardest first target.

## De-risking result (spike bowser-browser-3fo)

`BowserBrain.XAdapter` extracts the live timeline from a logged-in x.com
webview into a normalized tweet model (id, name, handle, text, permalink,
ISO timestamp, photos, has_video, metrics). **Live-verified: 4 real tweets
extracted with clean fields from the owner's session.** Normalization is
pure and unit-tested (5 cases). The data layer is viable.

Secondary finding: programmatic navigation of an x.com tab via
`location.href` is unreliable (the SPA/session restore fights it) — the real
app must drive navigation natively (load a fresh webview at the target URL),
not by scripting the SPA.

## Consequences

- New build track, separate from the macOS shell/brain.
- Next steps (children of bowser-browser-3fo): a headless extraction harness
  (navigate a background webview to a target, wait, extract — sidestepping
  the SPA-nav fragility); the SDUI declaration schema + a minimal native
  renderer; ModSmith-for-declarations.
- The macOS mod system is unchanged; this is an additional delivery target
  that reframes "mod" for a platform that forbids the original mechanism.
