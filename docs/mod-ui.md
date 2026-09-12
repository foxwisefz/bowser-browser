User mods belong to one browser profile. ModSmith stamps new Elixir, CSS, and JS files with a `bowser-profile` comment; untagged files belong to Default. Keep this comment when editing. Existing filenames owned by another profile cannot be overwritten; choose a distinct file and module name. Browser-wide means all windows in the owning profile, not all profiles.

Mod callbacks receive only their profile’s events and tabs in `hello`. `Surface.show/3`, chrome buttons, menu entries, toolbars, themes, and user content stay with that profile. Surface IDs remain local to the mod API; do not add profile prefixes yourself. `Chrome.open_tab/0,1,2` and `open_window/1` from a mod use its owning profile. Core browser features remain shared. Mods are trusted Elixir code, not a security sandbox.

# Native mod UI

Mods still send JSON view trees through `BowserBrain.Surface`. The shell renders
native SwiftUI/AppKit controls; existing `button`, `row`, `textfield`, `toggle`,
and panel styles retain their behavior. No Swift compilation is needed to use
these new builders. See `beam/example_mods/native_settings.ex` for a runnable
settings section covering the new layouts and interactions.

## Composition and identity

`vstack` and `hstack` accept shared options. Every other node can be decorated
with `ui(node, opts)`:

- `key`: stable string identity, unique among siblings. Use record IDs, not array
  indices. Form keys must additionally be unique across the whole surface.
- `width`, `height`, `min_width`, `max_width`, `min_height`, `max_height`:
  nonnegative point dimensions. `fill_width` and `fill_height` expand available space.
- `padding`, `alignment` (`:leading`, `:center`, `:trailing` for vertical stacks).
- `disabled`, `accessibility_label`, `help`.

Keys preserve mounted control state when siblings reorder. Legacy nodes without
keys fall back to position. A settings refresh no longer recreates the entire
section. Form drafts also survive unmounting when switching categories or detail
rows. Closing/removing the surface clears its stored drafts; restarting the shell
also clears them. Drafts are local UI state, not durable storage.

## Layouts

- `fields([field("Name:", input(:name), key: :name), ...])` aligns labels and
  controls in shared columns.
- `grid(children, columns: 3, spacing: 12)` creates equal-width columns (1–12).
- `group("Appearance", content)` creates a native group box.
- `list_detail(items, selection: "work", sidebar_width: 180, min_height: 320)`
  supplies a selectable sidebar and detail area. Items contain string `id`,
  `title`, optional SF `symbol`, and a `detail` tree. Selection is local to the
  shell; `selection` chooses the initial item. Removing it selects the first item.
- `text(value, style: :heading)` and `:body` add standard native typography;
  existing `:title`, `:caption`, and `:mono` remain available.

## Forms and acknowledged saves

```elixir
form("edit-work", %{"name" => "Work", "color" => "#3e63dd"},
  fields([
    field("Name:", input(:name), key: :name),
    field("Color:", input(:color, kind: :color), key: :color)
  ]), event: :save, required: [:name], labels: %{name: "a name"},
  response: state.response)
```

`input` binds to the nearest form. Kinds are `:text`, `:multiline`, `:toggle`, `:color`, and
`:choice`. Choice inputs accept `columns` and options containing string `value`,
`label`, and optional image `path` or SF `symbol`. Images keep their aspect ratio.
Color values are hex strings; toggles are booleans. Use string keys in values.

Inputs update only the local draft. Save sends one event:

```elixir
%{"event" => "surface", "surface" => surface_id, "id" => "save",
  "value" => %{"request_id" => request_id, "values" => draft}}
```

Validate and persist in the brain, then re-show the same form with:

```elixir
response: form_response(request_id, {:ok, canonical_saved_values})
# or
response: form_response(request_id, {:error, %{"name" => "Already taken"}})
# or
response: form_response(request_id, {:error, "Could not write the settings"})
```

Keep the form's `values` updated to the persisted values on success. A matching
success replaces the baseline and draft; rejection preserves the draft and shows
field/form errors. Unrelated replies are ignored while a request is pending.
Submission disables editing and duplicate saves. A 15-second timeout permits retry
without dropping the draft; use request IDs for idempotency if your action creates
external resources. A late reply after timeout cannot acknowledge a later request.

`required` checks nonempty string inputs, with optional human-readable `labels`.
Other validation belongs in the brain. Revert restores the last accepted baseline.
`require_changes: false` enables initial submission for creation forms.
`submit_label` and `cancel_label` customize the action labels.

## Native document editing

Use `input(:body, kind: :multiline)` inside a form for a native, scrollable,
wrapping text editor with selection, clipboard and undo/redo. Newlines remain
part of one string. Add `fill_height: true` to the input, form and enclosing
vertical layout to fill a sidebar. Side toolbars accept widths of 16–800 points;
top/bottom bars accept heights of 16–200. Bars shrink to preserve page space in
small windows. Sidebar content aligns at the top.

```elixir
form("document-42", %{"body" => saved_text},
  input(:body, kind: :multiline, monospaced: true,
    preview: :markdown, placeholder: "Start writing…",
    editor_actions: [%{label: "Bold", prefix: "**", suffix: "**"}],
    fill_width: true, fill_height: true),
  event: :save, response: state.response, fill_height: true)
```

`input/1,2` accepts optional `monospaced:` (default false), `preview: :markdown`
and `editor_actions:` (default empty). Each action has a `label`, optional `help`,
`prefix` and `suffix`; it wraps the selected text in one undoable edit. With no
selection it inserts the delimiters and places the caret between them. These
options work with arbitrary text; actions are not tied to notes or Markdown.

The optional Write/Preview control renders the current unsaved draft natively.
Preview supports headings, bullet lists, quotes, fenced code and inline
emphasis/code/link labels. It does not execute HTML, fetch images or activate
links; tables and rich HTML are unsupported. Plain multiline editing needs no
preview or formatting actions. Editor state is local until form submission;
matching `form_response/2` acknowledges persistence. Keep form keys stable per
document so tree refreshes preserve drafts; disabling a surface removes drafts.

Private tools must store content through `Store` and use native form events.
Do not send private text through page evaluation/scripts or expose it to
page-origin messages. See `beam/example_mods/page_notes.ex` for an inline native
sidebar example with URL-bound saves and a 500 KB note limit. That limit belongs
to the example; general editor inputs inherit the surface transport limits.

## Sheets, popovers, and actions

`sheet(key, "New…", content, width: 480)` and
`popover(key, "Choose…", content, width: 320)` create native presentations opened
by a button. Their content is a regular tree; popover inputs can edit an enclosing
form. The width option sets presentation width, not trigger-button width.

`action("Save", event: :save, role: :primary)` uses a native button instead of the
panel row. Options include `:destructive` role, `disabled`, SF `symbol`,
`payload`, and `shortcut` (`:default` for Return, `:cancel` for Escape, or one
character for a Command shortcut). Use only one default action in a presentation;
forms already supply a default Save button.

`action("Done", action: :dismiss, shortcut: :cancel)` dismisses a presentation.
Inside a form it checks for unsaved changes. Forms prevent interactive dismissal
while dirty or saving. For a form inside a creation sheet, use
`dismiss_on_success: true`, `dismiss_on_cancel: true`, and `cancel_label: "Cancel"`.
Cancel explicitly discards the draft and closes the presentation.

The optional example keeps saved values in memory and is not installed
automatically into your live mods directory.

## Live tab-deck chrome

`magnify_strip` accepts ordinary trees in `header:` and `footer:`, with
`header_height:` / `footer_height:` (default 48, clamped to 0–240 points).
`chrome: "notch"` enables the rounded backing; `background: "#112233"` sets its
color. The slots participate in centering and magnification geometry.

For example, `header: vstack([profile_avatar(profile_id, size: 22),
profile_name(profile_id, size: 9)], spacing: 1)` follows the profile's current
identity, including renames. These primitives also work outside the deck.
Ordinary actions, dividers, stacks, and text can be composed in either slot.

Re-showing an existing surface ID replaces its tree in the same hosting view and
panel. It does not recreate browser windows or WebKit pages. After the native
renderer containing these primitives has been activated once, changing slot
content, layout, colors, and controls requires only a live surface update.
Adding a new native primitive still requires native capability activation.

For identity outside the tab container, `header_outside: true` reserves the
header's layout space but excludes it from the notch backing. The tab deck
uses a 82-point slot with an 18-point avatar, leaving a visible gap above the
upper shoulder. This option requires the renderer that implements it.

`profile_avatar(id, badge: true, size: 18)` surrounds the local profile artwork
with a black circle and a one-point profile-tint border. The optional badge adds
seven points of padding per side: an 18-point avatar produces a 32-point badge,
matching the 16-point shoulder radius of the 48-point notch. It introduces no
remote asset loading and requires a renderer supporting `badge`. The default
remains an unframed avatar. `profile_avatar/1,2` and `profile_name/1,2` bind to
profile edits; both accept shared `ui/2` layout options. Native size is clamped
to 8–128 points; `profile_name` also accepts `color:`. Surface trees are emitted
by mod code; the MCP tool catalog does not expose a separate view-node schema.

## Live website layouts

Mods compose native layout trees from live website views. A `row` places its
children left to right; a `column` places them top to bottom. Either can contain
website leaves or more containers, and a single website leaf is also a valid tree.

```elixir
alias BowserBrain.{Layout, Surface}
# wv is a webview ID in the mod's profile.
{:ok, created} = Surface.create_tab(wv, "https://example.com")
second = created["created"]
{:ok, created} = Surface.create_tab(wv, "https://example.org")
third = created["created"]

tree = Layout.row([
  Layout.webview(wv, weight: 2, min_width: 240),
  Layout.column([
    Layout.webview(second),
    Layout.webview(third, min_height: 180)
  ], resizable: true)
])
{:ok, _} = Surface.layout(wv, tree)
{:ok, state} = Surface.tab_layout(wv)
# state["tree"] includes the current nested divider proportions.
{:ok, _} = Surface.reset_layout(wv)
```

`Layout.webview/1,2`, `Layout.row/1,2`, and `Layout.column/1,2` construct ordinary
maps. All nodes accept `weight:` (any positive relative value, default 1),
`min_width:` and `min_height:` (nonnegative window points, default 0). Containers
also accept `resizable:` (default true). False fixes that container's dividers;
its children still resize with the window. Weights apply within each parent.
Minimum sizes propagate through the tree; when the window is too small, minimum
sizes compress proportionally to keep the layout within its bounds.

`Surface.create_tab/2` creates a background http(s) tab in the target window and
returns its ID. `Surface.layout/2` validates and applies a tree atomically.
`Surface.tab_layout/1` returns `"tabs"` (same-window IDs and URLs), `"panes"`
(visible leaf IDs), `"active"`, and `"tree"`. The returned tree records current
sizes after divider dragging and can be reapplied. `Surface.reset_layout/1`
retains all tabs and displays the active one. Surface calls return
`{:ok, state}` or `{:error, reason}`.

Leaves must reference unique existing tabs in the same window/profile. There
is no flat pane-count restriction. Validation bounds complexity at 16 levels
and 256 total nodes. Invalid trees leave the current arrangement untouched.
Saved apps do not expose this API.

The leaves are real `WKWebView` instances, not iframes; rearranging them retains
page, login and navigation state. Clicking a leaf focuses it for browser controls.
Closing a tab removes that leaf and simplifies empty/single-child containers,
keeping other pages mounted. Selecting a tab outside the tree returns to a
single page. The arrangement ends when the native window closes.

Build mod controls to apply/reset the tree, reuse IDs from `tab_layout/1`, and
refresh IDs after `hello`. Avoid creating tabs on every activation or initialization.
File Undo tracks mod source, not runtime layout/tab creation; a mod's cleanup
logic handles its runtime changes.

ModSmith's `website_layout` tool has `get`, `create_tab`, `set`, and `reset` actions.
`set` takes a `tree` using the same keys with string types: `"row"`, `"column"`,
`"webview"`, `"children"`, `"webview"` (tab ID), `"weight"`, `"min_width"`,
`"min_height"`, and `"resizable"`. Nested state verifies structure and sizes;
screenshots verify appearance.
