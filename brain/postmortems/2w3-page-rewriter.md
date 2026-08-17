# Post-mortem: the HN page rewriter (bowser-browser-2w3)

**Shipped 2026-08-17.** A single-file mod that rebuilds news.ycombinator.com
as dark story cards, toggled from a toolbar button or `:hn`. Verified live by
the owner, including hot-editing it against a running browser.

## What the demo was actually for

Not the cards. The demo forced the platform to grow up. Every gap it exposed
became infrastructure the same day:

- **Mods clobbered each other's scripts** (one global `set_scripts`) →
  owner-keyed `UserContent` registry; the engine gets the union.
- **Hand-rolled persistence in the mod** (search text, scroll) — the owner
  called it out ("you wrote that just for that mod?") → standard preservation
  script every page gets free; the mod shrank ~40 lines.
- **Edits only applied after a toggle** → `mod_reloaded` event from the
  Loader; save = live.
- **Resurrection logged you out** → engine-level cookie snapshot/replay via
  SiteDataManager; localStorage persisted via `config_dir`.

## Principles extracted

1. **State survives by living above the layer that dies.** Page values →
   sessionStorage; mod state → OTP process; session + cookies → brain;
   window frame → disk. Anything stored *in* a mortal layer is a bug
   (the cookie jar was exactly that).
2. **Per-mod bespoke code is a platform smell.** If a mod needs it, the next
   mod will too — promote it.
3. **Verify builds by artifact, not exit code.** A `| tail` swallowed a lib
   compile failure and shipped a stale dylib; SwiftPM separately claimed
   "Build complete!" on stale binaries. `bin/rebuild-host` + symbol grep is
   the rule now (see bd memories).

## Left open

- User scripts are host-guarded (`location.hostname` check in JS), not
  engine-filtered — fine solo, sloppy at scale.
- `webview: 0` targeting — content applies to the first webview; per-tab
  targeting comes later.
- Duplicate url_changed events (bowser-browser-y99), stale-engine handshake
  (bowser-browser-6m9).
