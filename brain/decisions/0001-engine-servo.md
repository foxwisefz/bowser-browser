# ADR 0001 — Engine: Servo (embedded)

**Status:** SUPERSEDED by [0008](0008-engine-wkwebview.md) (same day — one
day of engine fights was the experiment; the brain proved to be the product)

## Decision

Bowser's engine is **Servo**, embedded via its webview/embedding API in a Rust host.

## Why

- Owner explicitly rejected shipping Apple's engine ("screw safari... we don't need to ship apple's legacy") in favor of a lighter, modern engine.
- Servo is the only serious embeddable new engine in 2026: Rust, parallel layout, active embedding story (Verso, servoshell), arm64 macOS supported.
- Owning the engine gives **engine-level extensibility hooks** (native DOM access from the host) that no WKWebView/extension model could offer — this directly serves the vision.

## Alternatives rejected

- **WKWebView / WebKit from source** — Safari-identical speed but Apple's legacy + hosted-engine limits on deep hooks. Rejected on principle by owner.
- **Ladybird** — independent but monolithic, not built for embedding; we'd vendor internals. Highest risk.
- **Blitz** — HTML/CSS renderer only, no full JS/DOM; we'd be building half an engine.
- **Servo + WKWebView fallback tabs** — rejected; owner accepts breakage (see [0005](0005-compat-tolerance.md)), and two engines means two mod surfaces.

## Consequences

- Some real-world sites will break. Accepted (ADR 0005).
- We track Servo upstream; engine bugs may become our bugs.
