# Mobile experiment — not shipped

Deferred under `bowser-browser-3fo`. Desktop releases do not depend on this
project. It owns the X feed adapter/server, SDUI declarations, their tests,
and the iOS client. Shared desktop ModSmith and native surfaces remain in core.

Run the pure experiment tests explicitly:

```sh
cd experiments/mobile/beam
mix deps.get
mix test --no-start
```

For an explicitly requested live experiment, use a separate `BOWSER_HOME`
with its own authenticated browser session and engine. From this directory,
`BOWSER_HOME=/path/to/experiment iex -S mix` starts the desktop brain dependency
and the experimental XFeed/XServer services. This opens the experimental HTTP
listener; do not point it at your normal browser home or run it during desktop
verification. The iOS project is in `../ios`.

Desktop handoff schema4 excludes the former mobile service state. Schema3
generations cannot live-migrate into it; installation waits for a natural quit
for that one-time boundary change. Mobile experiment handoff is unsupported.
