# ModSmith workspace

ModSmith is a core native window: AppKit owns the window and SwiftUI renders
the mod list, conversation and composer. It opens from View → ModSmith,
`:do`, or a mod's existing pencil action. Saved apps forward the same protocol
through SiteAppHub, preserving their registered app scope.

## Flow

A new request chooses site or browser scope. Saved apps always use app scope.
Each created mod has a stable ID, conversation, pinned URL and file revisions.
Subsequent submissions include that ID; New mod explicitly clears selection.
Switching tabs does not retarget an existing mod's refinement.

The page changes live. Results retain the agent's summary, caveats and reported
checks. Only an explicit `status: "partial"` marks requested work unfinished; notes
are expandable details and do not determine status. Verification is
labelled as agent-reported, not an independent guarantee. Failed and interrupted
runs retain recorded drafts and expose undo. No action claims to transfer work
to another agent.

## Brain and wire protocol

`ModWorkshop` owns orchestration and persistence. `ModSmith` contains the
Claude CLI runner, streaming parser and generation prompt. `ModRevision` owns
file capture and restoration. The old generic Surface panel is replaced by
`ModSmithWindow.swift`.

Shell events use `event: "modsmith"` and actions `open`, `new`, `select`,
`submit`, `undo`, and `toggle`. `project` is the durable mod ID. Submissions
also include `text`, `scope`, `url`, `webview` and a client `request_id`.
The brain acknowledges the accepted request in `modsmith_state`; the composer
clears only the corresponding submitted draft, retaining edits typed meanwhile.

`modsmith_state` includes filtered projects, selection, global busy status,
progress and errors. Saved-app events gain their app identity from the hub's
registered connection; state routes back only to that app. One run executes at
a time. A second submission is rejected without consuming its draft.

The MCP bridge adds a per-run token out of band. Expired tokens cannot write.
ModSmith's CLI exposes only the Bowser MCP toolbox: filesystem changes must go
through the revision writer. Page tools target the selected tab, and draft/final
paths are validated against the chosen scope. Site Elixir mods must declare
the matching host. App mods remain CSS/JS only.

## Persistence and undo

`BOWSER_HOME/modsmith-workspace.json` stores projects, turns, selections and
revisions.

Before each write, the journal durably records the original content (or absence)
and intended content. Further drafts retain that original. Undo preflights all
paths and refuses to overwrite conflicting external edits. Disable/enable is
also recorded as a reversible revision. Interrupted work remains recoverable;
a persisted pending undo is retried on restart. Undo resets the CLI session so
its next response reads current files and the visible conversation.

Undo covers mod files, including newly created files. It does not reverse
website actions, network calls, or the mod's durable Store. Existing loaders
reapply file changes; content fingerprints detect same-second refinements and
restorations. Whole-mod runtime state is not snapshotted.

## Isolated development

From the desired checkout, build with `cd shell && swift build`, then use a
separate `BOWSER_HOME` with `bin/dev start`. `BowserBrain.Paths` derives the
engine path from that checkout; `BOWSER_ENGINE` can explicitly select a build.
Tests run with bridge connections, engine spawning and user-mod loading disabled.

Run `mix test` in `beam/` and `swift test` in `shell/`. To render the native
workspace at normal and compact widths, set `BOWSER_MODSMITH_RENDER` to an
existing output directory and run `swift test --filter ModSmithTests`.

## Native shell skins

Browser-wide mods can call `BowserBrain.Chrome.set_theme/1` to style the
native top bar and controls. This is independent of website CSS. Supported
keys (atoms or strings) are:

| Property | Value |
|---|---|
| `background`, `foreground` | Bar and title colors, `#rrggbb` |
| `button_background`, `button_foreground` | Button face and glyph colors, `#rrggbb` |
| `accent`, `border` | Command-button accent and bar/bevel border colors, `#rrggbb` |
| `button_style` | `"flat"` or `"beveled"` |
| `show_navigation` | `true` keeps navigation visible without hovering |
| `title_size` | 9–16 points |
| `corner_radius` | 0–12 points |

Call from `init_mod/1` and on `"mod_reloaded"`. The complete map replaces
that mod's previous theme; omitted values use native defaults. Invalid maps
return `{:error, :invalid_theme}` without changing the current theme.
The latest caller wins. Disabling or deleting it restores the preceding
mod's theme, or native defaults. `Chrome.reset_theme/0` removes only the
caller's theme. Themes replay on engine reconnect and apply to new browser
windows. Undo that removes theme code clears its previous styling as well.

`Chrome.theme/0` and the read-only `shell_theme` MCP tool return the brain's
effective map; they do not verify pixels. The built-in tab UI has no native
strip to skin: a tab dock/strip remains a separate Surface mod. These APIs
do not expose arbitrary AppKit layouts or restyle the Settings/ModSmith windows.

During generation, `put_mod(name, content)` writes an Elixir draft through
the same scoped revision journal used by final output. The tool returns compilation
and startup/reload results; theme runs then check `shell_theme` before reporting.
An unchanged draft from the current run can be finalized as `{"path":"mods/name.ex"}`
without regenerating its content. Other files still require full content.
Drafts and final files share one original snapshot for Undo. The tool requires
an active ModSmith run and is unavailable for saved apps.

See `beam/example_mods/aol_skin.ex` for a blue and silver AOL-inspired skin.
Copy it into the **desired profile's** `mods/` directory to apply it live;
rename it to `.ex.off` or remove it to restore the previous appearance.

## Native edge toolbars and window borders

`Chrome.put_toolbar(id, view, edge: :bottom, size: 32, style: %{...})`
adds or updates a process-owned bar in every browser window. The view uses
normal `BowserBrain.View` controls and layout. `edge` can be `:top`, `:bottom`,
`:left`, or `:right`; `size` is 16–200 points for top/bottom height and 16–800 for left/right width. Style accepts adaptive `background`, `foreground`, `border` and `accent` colors,
plus a scoped `palette`. Use semantic roles or light/dark variant maps; literal
`#rrggbb` values remain fixed. View DSL spacing controls the gaps between controls.

Bars reserve native webpage space, including when switching or warming tabs
and resizing windows. Horizontal bars span the width inside the window border;
side bars fill the middle. Bars sort by id within each edge. When the window
is too small, bar thickness scales down to retain page space. Up to 16 bars
are allowed across owners.

Controls emit normal `surface` events with `surface: "toolbar:<id>"` and
`webview` identifying the clicked window's active tab. Use that id for page
actions. Bar definitions are shared across windows, not independent per-tab
models. `Chrome.remove_toolbar(id)` only removes the caller's bar. Equal ids
from other owners are shadowed and restored when the winner goes away.

Call `put_toolbar` in `init_mod` and on `mod_reloaded`. Removal, Disable and
Undo clear ownership; engine reconnects and new windows inherit active bars.
`Chrome.toolbars()` and the `toolbars` MCP tool report the effective definitions.

`Chrome.set_theme` also accepts `window_border` (`#rrggbb`),
`window_border_width` (0–12 points), and `window_border_style` (`"flat"` or
`"beveled"`). This draws an inner outline on all four edges and reserves
its space. It preserves the macOS window shape, shadow, resizing, and traffic
lights. It follows normal theme ownership and reset behavior.

See `beam/example_mods/status_bar.ex` for a bottom status bar with a clickable
Home control and a full-window beveled outline. No Window Style editor is required.

## Native artwork and verification

`put_asset(name: "logo.svg", content: svg_source)` saves self-contained SVG
artwork beneath `assets/<project-id>/`, with the same revision and Undo handling
as code. Its `image_path` can be passed to `View.image(path: path, size: 48)`
in surfaces and toolbars. Images are square; the renderer reloads changed files.
Use paths/shapes and inline colors without scripts, entities or external resources.
Existing local PNGs also work, but a raster-upload interface is not provided.

`native_screenshot` returns a real screenshot of the selected visible browser
window as an MCP image plus its window id. `native_click(x, y, window)` dispatches
a click in that browser's native content, using top-left window coordinates from
the screenshot; it rejects website content. Capture again to verify effects.
Screen capture requires macOS permission. Separate floating panels and saved apps
are not currently targets. A failed capture is not evidence that the skin rendered.

Embedded CLI runs use explicit settings to exclude CLAUDE.md, hooks and automatic
memory, plus a focused ModSmith system prompt. OAuth authentication remains enabled.
Existing resumed transcripts may still contain context from their earlier runs.

## Floating panel dismissal

The panel × closes locally and tells the core Surface registry to suppress
background re-shows. It works without the optional Panels mod. The core adds
`View > <title>` while dismissed; `Surface.reshow(id)` also restores it.
Repeated dismissal is idempotent. Panel content is top-aligned and fitted at its
actual width; explicit owner-resized frames remain respected.

## Website layout tools

ModSmith can compose live website panes using the `website_layout` tool and
`BowserBrain.Surface.create_tab/2`, `layout/2`, `tab_layout/1`, and
`reset_layout/1`, with `BowserBrain.Layout.webview/1,2`, `row/1,2`, and `column/1,2`
builders. The native shell renders nested containers and sizing constraints; generated
mods choose the websites, controls and behavior. See [live website layouts](../docs/mod-ui.md#live-website-layouts)
for limits, lifecycle and examples. This capability does not require a resident
agent to implement a particular layout feature.

Native UI is composed around `View.state/3,4`: editors, previews, selectors and
command buttons bind to local fields independently. Mods choose their layout,
controls and styling. `View.flow/1,2` wraps arbitrary controls; formatting is an
ordinary command action, not built into the editor. State is isolated per toolbar
window and document key. See [native composition](../docs/mod-ui.md#composing-native-tools)
for contracts, lifecycle, examples and the native renderer extension boundary.

Native mod palettes inherit the effective window appearance. See the
[appearance contract](../docs/mod-ui.md#appearance-and-palettes) for semantic
roles, custom light/dark/high-contrast variants, scope inheritance and limits.
