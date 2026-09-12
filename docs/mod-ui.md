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

`input` binds to the nearest form. Kinds are `:text`, `:toggle`, `:color`, and
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

Mods can compose actual website tabs into native resizable rows and columns.
These are live `WKWebView` instances, so embedding restrictions on iframes do
not apply. Each tab retains its own navigation, storage and page state.

```elixir
alias BowserBrain.Surface
# wv is a webview ID from the mod's browser event, in its own profile.
{:ok, state} = Surface.create_tab(wv, "https://example.com")
right = state["created"]
{:ok, _} = Surface.layout_tabs(wv, [wv, right], axis: :horizontal, weights: [0.4, 0.6])
{:ok, layout} = Surface.tab_layout(wv)
# layout["tabs"] lists same-window tab IDs/URLs; "panes", "axis", "weights",
# and "active" describe the current arrangement, including dragged dividers.
{:ok, _} = Surface.reset_layout(wv)
```

`create_tab/2` creates a background http(s) tab in the target window and returns
its ID. `layout_tabs/2,3` arranges **2–4 distinct existing tabs from that same
window**. `axis: :horizontal` means side-by-side; `:vertical` means stacked.
Optional weights are relative numbers from 0.1 to 1, one per tab; defaults
are equal. Users can drag the native dividers. Nested layouts are unsupported.
Every call returns `{:ok, state}` or `{:error, reason}`; handle errors instead
of assuming the native shell accepted the layout.

Clicking a pane focuses it for navigation controls. Activating a tab outside
the arrangement or closing a pane returns to a single visible page. Other tabs
remain open. `reset_layout/1` also retains the tabs. Tabs cannot move across
windows or profiles through this API, and saved apps do not support it.

The arrangement belongs to the native window's lifetime. Build mod controls to
apply/reset it, reuse existing IDs from `tab_layout/1`, and refresh IDs after
`hello`. Avoid creating tabs on every activation or initialization. File Undo
tracks mod source, not runtime layout or tab creation; a mod's reset/cleanup
logic should handle its runtime changes.

ModSmith's `website_layout` MCP tool provides `get`, `create_tab`, `set`, and
`reset` actions scoped to the selected tab's window. It returns layout state so
the agent can verify IDs, orientation and divider proportions. Screenshots
remain the way to verify appearance.
