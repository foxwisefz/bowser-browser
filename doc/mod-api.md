# Mod API v1

*System doc. Built: bowser-browser-ae2. Protocol version: 1 (host sends
`{"op":"hello","v":1,"webviews":[...]}` on brain connect).*

## What a mod can do

| Capability | Elixir API | Mechanism |
|---|---|---|
| Navigate | `Browser.navigate(url)` | engine `WebView::load` |
| One-off JS | `Page.eval(code)` | `evaluate_javascript`, result round-trips |
| Persistent styles | `Page.set_styles([css])` | **engine-injected** user stylesheets — apply to every page load, survive navigation |
| Persistent scripts | `Page.set_scripts([js])` | engine-injected user scripts (content-script equivalent) |
| Toolbar buttons | `Chrome.add_button(id, title, symbol: "book")` | shell inserts real NSToolbar items in every window |
| Omnibar commands | type `:anything` in the omnibar | routed to mods, never to the web |

## Events (all arrive as `handle_event(map, state)` in mods)

- `url_changed` — `{"url", "webview"}`
- `title_changed` — `{"title", "webview"}`
- `load_status` — `{"status": 0 started | 1 head_parsed | 2 complete}`
- `console` — `{"level", "message", "webview"}` — every page console.log, live
- `chrome_click` — `{"id"}` — a mod toolbar button was clicked
- `omnibar_command` — `{"text"}` — omnibar input after the `:`
- `hello` — engine (re)connected; `{"v", "webviews"}`; re-assert chrome/styles here

## Semantics worth knowing

- `set_styles`/`set_scripts` **replace** the mod-owned set (`[]` clears);
  absent field leaves the other kind untouched. Applies on reload — the op
  reloads the page by default (`reload: false` to defer).
- `webview: 0` (default everywhere) = first live webview.
- Chrome state lives in the shell and applies to all windows, including ones
  opened later. After an engine restart, mods get `hello` and should re-add
  buttons/styles (engine state is gone, mod state isn't).
- Wire: `{"op":"chrome","chrome":"add_button",...}` passes through the host
  verbatim to the shell — the host stays policy-free.

## Known gaps (deliberate, for later versions)

- No DOM hooks beyond JS yet — servo 0.5.0's embedding API has no direct DOM
  surface; when it grows one (or we patch Servo), `Page` gains real hooks.
- No network interception (`load_web_resource` exists in the delegate — v2
  ad-block material). No navigation veto. No per-tab chrome targeting.
