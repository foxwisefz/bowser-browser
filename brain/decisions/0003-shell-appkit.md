# ADR 0003 — Shell UI: AppKit core + SwiftUI leaves

**Status:** accepted (2026-08-17, owner)

## Decision

The browser chrome is Swift: **AppKit** for windows, tab strip, omnibar, keyboard/responder chain; **SwiftUI** only for leaf views (panels, settings) where convenient.

## Why

- Speed is the base pillar; AppKit is where instant-feel window/tab control lives (structurally what Safari does).
- SwiftUI has known perf/control cliffs for heavy window + tab management; fine for leaves.

## Alternatives rejected

- **Pure SwiftUI** — dev speed, but perf/control gaps at the core.
- **Web-based chrome** — ultimate moddability but risks the speed pillar; moddability comes from BEAM-driven surfaces instead.

## Consequences

- Chrome mod surfaces must be exposed *through* the Swift shell as declarative surface points the Brain can drive — the shell stays thin, mods don't write Swift.
