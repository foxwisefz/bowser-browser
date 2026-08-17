# ADR 0002 — Mod runtime: Elixir/OTP ("BEAM is the browser's brain")

**Status:** accepted (2026-08-17, owner)

## Decision

The personalization/mod runtime is **Elixir on BEAM**, embedded/sidecar. Every mod is a supervised OTP process. Mods drive chrome surfaces and page mutations through a Rust↔BEAM bridge into Servo's DOM.

## Why

- Owner rejected JS/TS as the mod language ("slow as shit") and proposed OTP/Elixir explicitly: "it's literally for that" — hot code updates.
- BEAM hot code reloading = mods update in the *running* browser, no restart, ever. This is the core UX of "build your extension whenever you want."
- OTP supervision = a broken AI-generated mod crashes and restarts alone; the browser never goes down. Critical when mods are churned out on demand.

## Alternatives rejected

- **JS/TS everywhere** — web-native and agent-friendly, but rejected on performance and taste.
- **Lua chrome / JS pages** — two languages, no supervision story.
- **WASM/Rust hot-loaded mods** — fastest execution but loses OTP hot-upgrade + supervision.

## Consequences

- We must build and maintain the Rust↔BEAM bridge (port vs NIF: spike-gated, speed budget decides).
- Page mutations go through engine-level DOM hooks (we own Servo), not injected JS — supervision extends all the way to page mods.
- Agents writing mods write Elixir. Mod API design must make that ergonomic.
