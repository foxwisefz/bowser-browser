# How the Rust↔BEAM bridge works

*System doc. Spike: bowser-browser-4jh. Decision: ADR 0007 (port, not NIF).*

## Shape

BEAM opens the Rust host as an Erlang port:

```elixir
Port.open({:spawn_executable, host_path}, [:binary, {:packet, 4}])
```

- `{:packet, 4}`: the VM handles 4-byte big-endian length framing on both sides.
  Rust reads/writes `u32::from_be_bytes` length + payload on stdin/stdout
  (see `spikes/beam-bridge/portecho/src/main.rs` for the minimal loop —
  buffered reader/writer + explicit flush per frame matters).
- Port death → `{:EXIT, port, reason}` under OTP supervision → restart. Engine
  and Brain can each crash without killing the other.

## Measured cost (M2 Pro, idle, serial round-trips)

p50 6.4–13.5 µs and p99 ≤ ~29 µs across 32 B–16 KB payloads; ~69k–133k msg/s
*serial*. Rerun anytime: `elixir spikes/beam-bridge/bench.exs` (build portecho
first; machine must be idle or numbers lie).

## Gotchas

- stdout of the Rust host **belongs to the protocol** — a stray `println!` corrupts
  framing. All logging in the host must go to stderr.
- Payload encoding is not yet decided (ETF vs custom) — Mod API v1's call.
