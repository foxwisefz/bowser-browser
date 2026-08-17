# Architecture

Three layers, one machine (`arm64-apple-macosx`, macOS 15+):

```
┌──────────────────────────────────────────────┐
│  Shell (Swift)                               │  windows, tabs, omnibar, responder chain
│  AppKit core + SwiftUI leaves                │  thin: renders state, forwards intent
├──────────────────────────────────────────────┤
│  Host (Rust)                                 │  embeds Servo; owns the engine surface
│  Servo engine + Rust↔BEAM bridge             │  exposes DOM/engine hooks upward
├──────────────────────────────────────────────┤
│  Brain (Elixir / BEAM)                       │  every mod = a supervised OTP process
│  mod runtime, hot code reload, automation    │  crashes isolated, upgrades live
└──────────────────────────────────────────────┘
```

## Layer contracts

- **Shell (Swift, AppKit core + SwiftUI leaves).** What Safari actually does structurally: AppKit for windows/tab strip/keyboard/responder chain where perf and control live; SwiftUI only for leaves (panels, settings). The shell is deliberately *thin* — it displays state and forwards user intent; policy lives below.
- **Host (Rust).** Embeds Servo (the Verso/servoshell embedding path proves this works on arm64 macOS). Because we own the engine, page modification happens through **engine-level DOM hooks**, not sandboxed injected JS — this is the "extensibility never seen before" unlock. Also owns the bridge to BEAM (port or NIF — spike decides).
- **Brain (Elixir/BEAM, embedded/sidecar).** The mod runtime. Each mod is an OTP process under a supervisor: a crashing mod restarts alone, never takes the browser down. Hot code reloading means edit `.ex` → mod updates in the running browser, zero restarts. Mods drive both chrome surfaces (via Shell) and page mutations (via Host's DOM hooks).

## Data flow

- User intent: Shell → Host (navigation, input) and Shell → Brain (mod-owned surfaces).
- Page events: Servo → Host → Brain (mods subscribe to DOM/navigation/network events).
- Mutations: Brain → Host → Servo DOM (pages) and Brain → Shell (chrome).

## Open questions (spike-gated, see beads)

- Bridge transport: Erlang port (process isolation, simpler) vs NIF (latency). Speed budget decides.
- Where the mod-facing API schema lives and how it's versioned.
- BEAM embedded in-process vs supervised sidecar process.
