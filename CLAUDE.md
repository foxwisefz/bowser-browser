# Bowser — agent entry point

A completely personalizable browser. One machine, one target: `arm64-apple-macosx`, macOS 15+.

## Read first

- **`brain/README.md`** — knowledge-layer map; start here every session.
- **`brain/vision.md`** — the three pillars: speed as base, this machine only, extensibility like never seen before.
- **`brain/architecture.md`** — Swift shell (AppKit core + SwiftUI leaves) / Rust host embedding Servo / Elixir-BEAM mod brain.
- **`brain/decisions/`** — settled ADRs. Reopen via a bead, never by building around one.

## Task tracking

`bd` (beads) for ALL tasks — no TodoWrite, no markdown TODOs. Run `bd prime` at session start; `bd ready` for available work. `bd remember` for operational gotchas.

## Build & Test — TDD, non-negotiable

- **Every change ships with tests.** Bug fixes START with a failing test that reproduces the bug; features extend the suites as they're built. "It compiles" is not verification — tonight's history proves both toolchains lie ("Build complete!" on stale binaries, exit codes eaten by pipes).
- Run before every delivery:
  ```sh
  cd beam && mix test          # brain: ExUnit (beam/test/)
  cd shell && swift test       # shell: XCTest (shell/Tests/BowserTests/)
  bin/install                  # deliver: what the owner is using only changes here
  ```
- Testable-by-design: pure logic lives in `static`/public functions (e.g. `BrowserWindowController.normalize`, `EngineView.parseCSSColor`, `ModSmith.extract_json/validate`). If logic is hard to test, extract it first.
- UI/behavior that can't run headless gets verified via probe mods (`~/.bowser/mods` is an RPC channel into the running brain) or explicit owner check — never assumed.

## Hard rules

- Speed regressions are bugs. No cross-platform abstractions. No traditional extension platform.
- VCS is **jj (jujutsu)**, colocated with git — use `jj st`, `jj describe`, `jj commit`, `jj new`; never raw git for commits. Conservative profile: don't commit/push unless asked.
- **One workspace: this one.** Never create a per-bead jj workspace or git worktree.
- **The owner runs the INSTALLED Bowser, not the working copy.** `bin/install` builds both halves into `~/.bowser/app/` (Bowser.app bundle + a brain release + bin/) and restarts it; `bin/bowser start|stop|restart|status|log` controls it. A dev brain (`iex -S mix` in beam/) supervises `shell/.build/debug/Bowser` and is for development only — never run both at once (they fight over ~/.bowser sockets; `bin/bowser stop --all` clears dev brains). Working-copy builds and edits do NOT reach the owner until `bin/install` (`--shell-only` rolls just the browser, `--brain-only` restarts just the brain; the shell build is DEBUG by default until the release-only SIGTRAP is fixed).
