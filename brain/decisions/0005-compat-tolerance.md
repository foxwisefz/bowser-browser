# ADR 0005 — Web compat: breakage accepted, no fallback engine

**Status:** accepted (2026-08-17, owner)

## Decision

Sites Servo can't render **stay broken** in Bowser; the owner opens them in Safari by hand. No per-tab WKWebView fallback, no second engine.

## Why

- Owner's explicit call: "I'll live with breakage." This is a power-user daily driver in progress.
- A fallback engine doubles the mod surface and reintroduces the Apple engine rejected in ADR 0001.

## Consequences

- Keep a lightweight `doc/broken-sites.md` list as they're hit — it doubles as an upstream-Servo watch list.
- "Open current URL in Safari" should be a one-keystroke escape hatch in the shell (cheap to build, file a bead when shell exists).
