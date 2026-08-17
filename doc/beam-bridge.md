# How the Rust↔BEAM bridge works

*System doc. Spike: bowser-browser-4jh (ADR 0007). Built: bowser-browser-rv2.*

## Topology (as built)

The engine host (`libbowser_host` inside the Bowser app) **listens** on a Unix
domain socket at `~/.bowser/brain.sock`; the Elixir brain (`beam/`, app
`bowser_brain`) connects as a client and reconnects forever — either side can
restart without the other noticing. Framing is `{packet,4}` (4-byte BE length
+ payload); Erlang's `gen_tcp` handles it natively:

```elixir
:gen_tcp.connect({:local, path}, 0, [:binary, packet: 4, active: true])
```

Payload is **JSON v0** (Elixir's built-in `JSON`, Rust's `serde_json`) — the
final encoding decision belongs to Mod API v1 (bowser-browser-ae2).

## Message protocol v0

Brain → engine: `{"op":"navigate","webview":W,"url":U}`,
`{"op":"eval_js","id":N,"webview":W,"code":C}`. `webview: 0` = first live one.
Engine → brain: `{"op":"event","event":"url_changed"|"title_changed"|"load_status",...}`,
`{"op":"js_result","id":N,"ok":bool,"value":...}`.

## Threading (host side, brain.rs)

Socket accept/read runs on a dedicated thread; inbound messages queue and a C
callback (fires on the socket thread!) tells Swift to enqueue
`bowser_brain_pump()` on the main queue, where engine calls are legal.
Outbound `brain::send` is called from the main thread (delegate events,
eval_js results) and writes directly; drops silently when no brain connected.

## Measured cost (spike, idle M2 Pro, pipe transport)

p50 6.4–13.5 µs round-trip, p99 ≤ ~29 µs across 32 B–16 KB; ~69k–133k msg/s
serial. UDS is comparable. Rerun: `elixir spikes/beam-bridge/bench.exs`.

## Gotchas

- The C on-message callback fires on the socket thread — Swift's handler MUST
  be a file-scope nonisolated func that only does `DispatchQueue.main.async`
  (see the swift6-c-callback-trap memory).
- Mods live in `~/.bowser/mods/*.ex`; the Loader polls mtimes at 500ms and
  compiles straight into the running VM. Broken file → old code keeps running.
- `eval_js` callbacks fire during `spin_event_loop`; results are sent to the
  brain from inside that callback (safe: send only touches the socket).
