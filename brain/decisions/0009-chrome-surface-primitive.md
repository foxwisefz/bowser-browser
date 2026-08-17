# ADR 0009 — Chrome extensibility: the surface primitive, not surface points

**Status:** accepted (2026-08-17, owner: "I want no limits on chrome/shell");
**amended same day** — content substrate is native declarative UI, not HTML
(owner: "is html/js the thing to do here?" — no)

## Decision

Chrome moddability is delivered by ONE generic primitive, not a curated list
of surface points: **mods create, position, and own surfaces** (floating
panels, sidebars, HUDs, sheets — NSWindow/NSPanel flavors). Surface content
is a **declarative view tree sent as data from Elixir**, rendered by the
shell as native SwiftUI; interaction events flow back over the socket. The
LiveView model with SwiftUI as the client. The shell's contract: positioned,
layered surfaces that render mod-described native UI and report events. All
state and policy is mod-side; a new tree = instant native re-render.

HTML/JS was considered and rejected as the substrate: it reintroduces web
tech as chrome (contra ADR 0003's speed pillar) and a second mod language
(contra ADR 0002's one-language principle). A webview may someday exist as
one WIDGET inside a native surface for exotic rendering — never as the
foundation. The widget vocabulary (stacks, text, button, slider, field,
list, tree, divider, image, spacer; canvas later) is the growable part;
arrangement, windows, anchoring, and behavior are unbounded from day one.

## Why

- Enumerated surface points (a "sidebar API", a "toolbar API") cap creativity
  at what we predicted — the same flaw as a command-DSL for ModSmith. The
  owner's counterexample: a GIMP-style floating tool palette next to the main
  window, for Twitter. No list would have contained it; the primitive
  expresses it trivially.
- HTML surfaces are hot-reloadable and maximally LLM-writable; ModSmith
  inherits every chrome idea for free.
- Re-reads ADR 0003 without breaking it: "thin shell" means no policy in the
  shell, and a compositor of mod-owned rectangles is the thinnest shell.
  Speed-critical core chrome (omnibar, native tab strip until a mod claims
  it) stays native.

## Tiers above the primitive

1. **Surfaces** (seconds, omnibox-able) — ~95% of chrome ideas.
2. **Agent** — for missing primitives, the agent writes Swift; resurrection
   makes delivery a blip; each ask ends by generalizing into a primitive.
3. **Self-serve native** (only if ever needed) — .swift shell-mods with
   auto-rebuild + supervised respawn.

## Consequences

- Bead 7q8 generalizes from "sidebar panel" to the full surface primitive.
- Tab/window model data (5y4) still comes from the shell — surfaces render
  it, they don't own it.
