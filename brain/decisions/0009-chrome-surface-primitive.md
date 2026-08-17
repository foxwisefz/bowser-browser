# ADR 0009 — Chrome extensibility: the surface primitive, not surface points

**Status:** accepted (2026-08-17, owner: "I want no limits on chrome/shell")

## Decision

Chrome moddability is delivered by ONE generic primitive, not a curated list
of surface points: **mods create, position, and own rectangles** (floating
panels, sidebars, HUDs, sheets — NSWindow/NSPanel flavors) whose content is
mod-supplied HTML with a JS↔brain event bridge. The shell's contract:
positioned, layered rectangles that render mod content and report events.
All policy, layout, and content is mod-side.

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
