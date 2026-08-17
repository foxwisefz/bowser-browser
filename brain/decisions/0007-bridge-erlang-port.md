# ADR 0007 — Rust↔BEAM bridge: Erlang port, not NIF

**Status:** accepted (2026-08-17, spike bowser-browser-4jh)

## Decision

The Host↔Brain bridge is an **Erlang port**: the Rust host is a separate OS process
speaking `{packet, 4}` length-prefixed binary frames over stdin/stdout with BEAM.
No NIFs in the hot path.

## Why — measured on this machine (M2 Pro, idle)

Serial round-trip through a release-build Rust echo port:

| payload | p50 | p99 | p999 | serial throughput |
|---|---|---|---|---|
| 32 B | 6.4 µs | 20.4 µs | 44.5 µs | ~133k msg/s |
| 1 KB | 10.2 µs | 19.6 µs | 46.5 µs | ~98k msg/s |
| 16 KB | 13.5 µs | 28.8 µs | 50.9 µs | ~69k msg/s |

- A 60 Hz frame budget is 16,667 µs; a bridge round trip is **<0.1% of a frame**. DOM-hook
  event rates (even 10k msg/s) use a fraction of serial capacity — and the port isn't limited
  to serial use.
- **Crash isolation both ways**: a NIF crash kills the whole BEAM (and with it every mod);
  a port crash is just a process exit that OTP supervision restarts. Isolation is the entire
  point of ADR 0002 — the port model extends it across the language boundary.
- No NIF scheduler-blocking hazards, no dirty-scheduler tuning, no rustler dependency.

## Alternatives

- **NIF (rustler)** — ~1 µs calls, but crash-couples engine and Brain and complicates the
  build. Not measured in the spike: port numbers were so far inside budget that NIF's only
  win (latency) buys nothing perceptible. Revisit only if profiling ever shows the bridge
  on a hot path (then: benchmark first).

## Consequences

- Wire protocol (framing = `{packet,4}`; payload encoding TBD — ETF via
  `:erlang.term_to_binary` vs custom) is decided in Mod API v1 (bowser-browser-ae2).
- Spike code lives in `spikes/beam-bridge/`; see `doc/beam-bridge.md`.
