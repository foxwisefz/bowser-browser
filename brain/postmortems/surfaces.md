# Post-mortem: the surface layer (7q8, 5y4, 2un, e1i)

**Shipped 2026-08-18.** Mods now own native chrome: declarative view trees
from Elixir rendered as SwiftUI in translucent floating panels; tab model
with opener lineage; page→brain duplex (`window.bowser.emit`). Proving mods:
page tools, opener-nested tab tree, and the Twitter nav semantic mirror.

## Traps found (each cost real debugging, each now has a rule)

1. **Non-key windows dim standard controls.** Non-activating panels are
   never key; macOS grays out bordered/prominent button styles there. Any
   "active" look must be explicitly painted (gradient fill), never a stock
   control style. Two invisible-highlight rounds before this was found.
2. **Hover state cannot live in non-activating panels.** Mouse-exit events
   are dropped for non-key windows; any enter/exit hover implementation
   eventually sticks. Rows use synchronous pressed-state feedback only.
3. **Round the backdrop, not the layer.** `layer.cornerRadius` on an
   NSVisualEffectView clips the view while the behind-window blur/shadow
   stays rectangular. Use `maskImage` + `invalidateShadow()`; draw hairlines
   in SwiftUI so they follow the curve.
4. **The port-zombie cat** (respawn stalls all evening): with
   `:stderr_to_stdout`, every descendant of the spawned wrapper holds the
   port's output pipe as fd2. An orphaned watcher `cat` kept the Erlang port
   open after the wrapper died — no EOF, no exit_status, supervisor
   *correctly* saw a live port, no respawn. Fixed in bin/engine-wrapper
   (watcher stderr → /dev/null, children reaped); Engine self-heals via
   Port.info liveness regardless.
5. **Event ordering is part of the producer contract.** tab_activated fired
   before tab_opened (windowDidBecomeKey during creation) → duplicate rows.
   hello must be a full snapshot (ids + urls + titles + active), not an id
   list — already-loaded pages never re-fire title_changed.

## Patterns worth keeping

- **The mods dir is an RPC channel into the running brain.** A dropped
  "probe" mod File.write!ing `:sys.get_state` found the port zombie; a
  "medic" mod `Code.compile_file`ing lib source hot-patched the running
  Engine and revived the browser with zero restarts.
- **Consumers converge, producers snapshot.** Mods self-heal from any event
  naming an unknown entity; hello carries authoritative state.
- Delivery discipline held: mods hot-swap in <1s; shell changes ride the
  supervised respawn (~1.5s, session intact).
