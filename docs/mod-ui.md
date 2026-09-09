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
legacy panel row. Options include `:destructive` role, `disabled`, SF `symbol`,
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
