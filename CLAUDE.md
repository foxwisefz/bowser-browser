# Bowser — agent entry point

A completely personalizable browser. One machine, one target: `arm64-apple-macosx`, macOS 15+.

## Read first

- **`brain/README.md`** — knowledge-layer map; start here every session.
- **`brain/vision.md`** — the three pillars: speed as base, this machine only, extensibility like never seen before.
- **`brain/architecture.md`** — Swift shell (AppKit core + SwiftUI leaves) / Rust host embedding Servo / Elixir-BEAM mod brain.
- **`brain/decisions/`** — settled ADRs. Reopen via a bead, never by building around one.

## Task tracking

`bd` (beads) for ALL tasks — no TodoWrite, no markdown TODOs. Run `bd prime` at session start; `bd ready` for available work. `bd remember` for operational gotchas.

## Hard rules

- Speed regressions are bugs. No cross-platform abstractions. No traditional extension platform.
- VCS is **jj (jujutsu)**, colocated with git — use `jj st`, `jj describe`, `jj commit`, `jj new`; never raw git for commits. Conservative profile: don't commit/push unless asked.
