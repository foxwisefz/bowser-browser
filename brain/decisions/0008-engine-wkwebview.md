# ADR 0008 — Engine: WKWebView; Servo host parked (supersedes 0001)

**Status:** accepted (2026-08-17, owner — after one full day of building on Servo)

## Decision

The engine is **WKWebView** (Apple's hosted WebKit). The Swift shell owns it
directly and implements the brain protocol natively — the Rust/Servo host
stays in-tree, dormant, revivable. The **UDS JSON protocol is the engine
abstraction boundary**; everything above it (brain, mods, Session, Engine
supervision, chrome surfaces) is untouched by the swap.

## Why (owner: "trying not to pick too many fights")

- One day of Servo yielded: input events not reaching document listeners,
  duplicate navigation events, no cookie persistence, async document.cookie —
  each fixable, each a fight, with compat breakage still ahead.
- The differentiator is the brain (OTP mods, hot reload, resurrection,
  LLM-on-demand mods), not the engine. Every mod surface we built uses user
  scripts + eval — exactly WKWebView's mature API. Servo 0.5's embedding
  exposed no engine-level DOM/network hooks anyway; those were potential,
  not possessed.
- "Speed: do whatever Safari does" becomes literally true.

## What we knowingly give up (the implications table, condensed)

- **Response-body rewriting** (transform HTML/API responses before parse) —
  impossible on WKWebView directly. Back door if ever needed: macOS 14+
  `proxyConfigurations` + a local MITM proxy under brain supervision.
- **Deep JS instrumentation / same-day engine fixes** — file radars instead.
- Request *blocking* survives via declarative content blockers (Safari's
  own ad-block tech). Everything else in the product vision is covered.

## What we gain besides peace

- WKWebView is multiprocess: WebContent crashes don't touch the window
  (obsoletes the Servo-multiprocess bead uq9).
- Cookies/localStorage persist natively (WKWebsiteDataStore) — brain-side
  cookie replay becomes redundant belt-and-suspenders.
- Full compat: logins, banking, SPAs.

## Revival path

`host/` (Rust/Servo) remains buildable via bin/rebuild-host. If engine-level
hooks ever justify the tax, the protocol boundary means a Servo (or other)
host can return without touching the brain.
