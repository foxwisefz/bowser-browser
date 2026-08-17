# How the Servo embedding works (`host/`)

*System doc — life of the system. Spike: bowser-browser-8wt.*

## The short version

`bowser-host` is a Rust binary that embeds Servo via the **published crates.io crates**
(`servo = "=0.5.0"`, released from servo main). No git submodule, no vendored engine,
no `./mach`. `cargo build --release` is the whole build.

## Key facts

- **Servo publishes to crates.io** (since 2026; `servo` 0.5.0 published 2026-08-17,
  tracking main @ `a986ae1`). Pin exactly (`=0.5.0`) — the embedding API is pre-1.0
  and breaks between releases. Upgrades are deliberate events: bump pin + fix breakage + commit.
- **Toolchain**: pinned to upstream's `rust-toolchain.toml` (1.97.1). Keep our pin
  matched to the servo release we're on.
- **SpiderMonkey** (`mozjs_sys` 140.x) compiles from source inside the crate build —
  the long pole of a cold build. Needs python3 + Xcode CLT, both present.
- **Embedding API shape** (all re-exported from the `servo` crate):
  - `ServoBuilder` → `Servo` (the engine instance; needs an `EventLoopWaker`)
  - `WebViewBuilder::new(&servo, rendering_context)` → `WebView` (per-tab)
  - `WebViewDelegate` trait — the hook surface (frame-ready, and much more to explore)
  - `WindowRenderingContext::new(display_handle, window_handle, size)` — GL surface
    from raw-window-handle; this is how the AppKit shell will host the engine later
    (NSView exposes raw handles).
  - Drive it: `servo.spin_event_loop()` on wake/window events; `webview.paint()` +
    `rendering_context.present()` on redraw.
- `embedder_traits` is the published `servo-embedder-traits` crate (for `EventLoopWaker`).
- Support-crate versions (euclid 0.22, winit 0.30.13, webrender_api 0.70, rustls 0.23)
  must match servo's workspace pins — check servo's root `Cargo.toml` on upgrade.
- rustls needs its `aws_lc_rs` default provider installed at startup or networking panics.

## Why winit (temporarily)

The spike uses winit for a window because that's upstream's example shape. Per ADR 0003
the real chrome is AppKit; the migration path is handing Servo a `WindowRenderingContext`
built from the NSView's raw window/display handles instead of winit's.

## Build config

- Single target enforced in `.cargo/config.toml`: `aarch64-apple-darwin`,
  `-C target-cpu=native` (ADR 0006).
- `dev` profile compiles deps at opt-level 2 — pure-debug Servo is unusably slow.
