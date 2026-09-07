defmodule BowserBrain.View do
  @moduledoc """
  View-tree builders (ADR 0009): mods describe native UI as data; the shell
  renders it as SwiftUI. Import this module and compose:

      import BowserBrain.View

      vstack [
        text("Page tools", style: :title),
        button("Dark mode", event: :dark, active: state.dark),
        slider(:zoom, min: 0.5, max: 2.0, value: state.zoom, label: "Zoom"),
        divider(),
        textfield(:search, placeholder: "Search…")
      ]

  Widget events arrive in the mod as
  `%{"event" => "surface", "surface" => surface_id, "id" => event_id, "value" => v}`.
  """

  def vstack(children, opts \\ []) when is_list(children) do
    ui(%{t: "vstack", children: children, spacing: Keyword.get(opts, :spacing, 8)}, opts)
  end

  def hstack(children, opts \\ []) when is_list(children) do
    ui(%{t: "hstack", children: children, spacing: Keyword.get(opts, :spacing, 8)}, opts)
  end

  @doc "style: :title | :caption | nil"
  def text(value, opts \\ []) do
    %{t: "text", value: to_string(value), style: Keyword.get(opts, :style)}
  end

  @doc "opts: event: (required), active:, symbol: (SF Symbol), indent:, payload:, compact: (small row)"
  def button(label, opts) do
    %{
      t: "button",
      label: to_string(label),
      event: to_string(Keyword.fetch!(opts, :event)),
      active: Keyword.get(opts, :active, false),
      symbol: Keyword.get(opts, :symbol),
      indent: Keyword.get(opts, :indent, 0),
      payload: Keyword.get(opts, :payload),
      compact: Keyword.get(opts, :compact, false)
    }
  end

  @doc "Sends {id, value} when the user releases the thumb."
  def slider(event, opts \\ []) do
    %{
      t: "slider",
      event: to_string(event),
      min: Keyword.get(opts, :min, 0.0),
      max: Keyword.get(opts, :max, 1.0),
      value: Keyword.get(opts, :value, 0.5),
      label: Keyword.get(opts, :label)
    }
  end

  @doc """
  Native color picker. Sends {id, "#rrggbb"} shortly after the color stops
  changing (debounced in the shell, so a drag on the wheel is one event).
  opts: value: "#rrggbb" | nil, label:.
  """
  def colorpicker(event, opts \\ []) do
    %{
      t: "colorpicker",
      event: to_string(event),
      value: Keyword.get(opts, :value),
      label: Keyword.get(opts, :label, "")
    }
  end

  @doc """
  A list row: title + optional one-line subtitle on the left (with an
  optional leading SF Symbol / image path / color swatch), controls on the
  right. The pattern every settings and extensions list uses (icon · name ·
  description · toggle). opts: subtitle:, symbol:, path:, swatch: "#rrggbb",
  trailing: [nodes], event:/payload: (whole row clickable when given).
  """
  def row(title, opts \\ []) do
    %{
      t: "row",
      title: to_string(title),
      subtitle: Keyword.get(opts, :subtitle),
      symbol: Keyword.get(opts, :symbol),
      path: Keyword.get(opts, :path),
      swatch: Keyword.get(opts, :swatch),
      trailing: Keyword.get(opts, :trailing, []),
      event: Keyword.get(opts, :event) && to_string(Keyword.get(opts, :event)),
      payload: Keyword.get(opts, :payload)
    }
  end

  @doc "A switch. Sends {id, true|false} on change. opts: on:, payload:, label:."
  def toggle(event, opts \\ []) do
    %{
      t: "toggle",
      event: to_string(event),
      on: Keyword.get(opts, :on, false),
      payload: Keyword.get(opts, :payload),
      label: Keyword.get(opts, :label, "")
    }
  end

  @doc "A small-caps group header, like the category labels in a settings sidebar."
  def section(title), do: %{t: "section", value: to_string(title)}

  @doc "Sends {id, value} on Enter."
  def textfield(event, opts \\ []) do
    %{
      t: "textfield",
      event: to_string(event),
      placeholder: Keyword.get(opts, :placeholder, ""),
      value: Keyword.get(opts, :value, "")
    }
  end

  @doc """
  Floating-particle emitter (rising characters with drift/fade). Use inside
  a :toolbar_overlay surface for chrome effects.

      particles(chars: ["♪", "♫"], rate: 3.0, active: state.playing)
  """
  def particles(opts \\ []) do
    %{
      t: "particles",
      chars: Keyword.get(opts, :chars, ["♪", "♫", "♩", "♬"]),
      rate: Keyword.get(opts, :rate, 2.5),
      active: Keyword.get(opts, :active, true)
    }
  end

  def divider, do: %{t: "divider"}
  def spacer(opts \\ []), do: %{t: "spacer", min: Keyword.get(opts, :min, 0)}

  @doc "image(\"sf.symbol\") or image(path: \"/abs/file.png\", size: 16)"
  def image(symbol) when is_binary(symbol) or is_atom(symbol),
    do: %{t: "image", symbol: to_string(symbol)}

  def image(opts) when is_list(opts) do
    %{
      t: "image",
      path: Keyword.get(opts, :path),
      symbol: Keyword.get(opts, :symbol),
      size: Keyword.get(opts, :size, 16)
    }
  end

  @doc """
  Proximity-magnification icon strip — the physics half of dock-like UIs.
  The shell owns cursor tracking + distance-falloff scaling; you supply
  items and receive only discrete select events (value = item id).

      magnify_strip(
        [%{id: 1, path: favicon_path, active: true, title: "YT Music"},
         %{id: 2, symbol: "globe", active: false}],
        size: 28, magnify: 2.0, event: :select)

  Best inside kind: :edge surfaces (which add peek/reveal sliding).
  """
  def magnify_strip(items, opts \\ []) when is_list(items) do
    %{
      t: "magnify_strip",
      items: items,
      size: Keyword.get(opts, :size, 28),
      magnify: Keyword.get(opts, :magnify, 1.9),
      event: to_string(Keyword.get(opts, :event, :select))
    }
  end

  @doc "Stable identity and shared layout/control options. Keys must be unique among siblings."
  def ui(node, opts) when is_map(node) do
    shared = Keyword.take(opts, [:key, :width, :height, :min_width, :max_width, :min_height,
      :max_height, :fill_width, :fill_height, :padding, :alignment, :disabled,
      :accessibility_label, :help]) |> Map.new()
    shared = if Map.has_key?(shared, :key), do: Map.update!(shared, :key, &to_string/1), else: shared
    Map.merge(node, shared)
  end

  @doc "Native bordered action. role: :primary/:destructive; shortcut: :default/:cancel or a command-key character. action: :dismiss closes a presentation."
  def action(label, opts \\ []) do
    %{t: "action", label: to_string(label), event: to_string(Keyword.get(opts, :event, :click)),
      payload: Keyword.get(opts, :payload), role: Keyword.get(opts, :role),
      shortcut: Keyword.get(opts, :shortcut), symbol: Keyword.get(opts, :symbol),
      action: Keyword.get(opts, :action)} |> ui(opts)
  end

  @doc "Equal-width native grid. columns: 1..12."
  def grid(children, opts \\ []) when is_list(children),
    do: ui(%{t: "grid", children: children, columns: Keyword.get(opts, :columns, 2), spacing: Keyword.get(opts, :spacing, 12)}, opts)

  @doc "Aligned label/control columns. Children are field/3 nodes."
  def fields(children, opts \\ []), do: ui(%{t: "fields", children: children}, opts)
  def field(label, content, opts \\ []), do: ui(%{label: to_string(label), content: content}, opts)
  def group(label, content, opts \\ []), do: ui(%{t: "group", label: to_string(label), content: content}, opts)

  @doc """
  Local draft with atomic submission. key is unique within the surface. Inputs bind
  to string keys in values. Emits value: %{request_id: uuid, values: draft} to event.
  Re-show this form with response: form_response(request_id, result) to acknowledge.
  Required fields are nonempty strings. Server validation remains authoritative.
  """
  def form(key, values, content, opts \\ []) when is_map(values) do
    %{t: "form", key: to_string(key), values: values, content: content,
      event: to_string(Keyword.get(opts, :event, key)),
      required: Enum.map(Keyword.get(opts, :required, []), &to_string/1),
      labels: Map.new(Keyword.get(opts, :labels, %{}), fn {k, v} -> {to_string(k), v} end),
      require_changes: Keyword.get(opts, :require_changes, true),
      dismiss_on_success: Keyword.get(opts, :dismiss_on_success, false),
      dismiss_on_cancel: Keyword.get(opts, :dismiss_on_cancel, false),
      submit_label: Keyword.get(opts, :submit_label, "Save Changes"),
      cancel_label: Keyword.get(opts, :cancel_label, "Revert"),
      response: Keyword.get(opts, :response)} |> ui(opts)
  end

  def form_response(request_id, {:ok, values}) when is_map(values),
    do: %{request_id: request_id, ok: true, values: values}
  def form_response(request_id, {:error, errors}) when is_map(errors),
    do: %{request_id: request_id, ok: false, errors: errors}
  def form_response(request_id, {:error, message}),
    do: %{request_id: request_id, ok: false, error: to_string(message)}

  @doc "Form-bound input. kind: :text/:toggle/:color/:choice. Choice options: %{value: string, label: string, path: image_path or symbol: sf_symbol}."
  def input(name, opts \\ []) do
    %{t: "input", key: to_string(name), field: to_string(name), kind: Keyword.get(opts, :kind, :text),
      label: Keyword.get(opts, :label, to_string(name)), placeholder: Keyword.get(opts, :placeholder),
      columns: Keyword.get(opts, :columns, 4), options: Keyword.get(opts, :options, [])} |> ui(opts)
  end

  @doc "Native sheet opened by a button; content is another tree. Include action(..., action: :dismiss) to close."
  def sheet(key, label, content, opts \\ []), do: presentation("sheet", key, label, content, opts)
  @doc "Native popover opened by a button; inputs inherit the enclosing form draft."
  def popover(key, label, content, opts \\ []), do: presentation("popover", key, label, content, opts)
  defp presentation(type, key, label, content, opts),
    do: ui(%{t: type, key: to_string(key), label: to_string(label), content: content, content_width: Keyword.get(opts, :width, 480)}, Keyword.delete(opts, :width))

  @doc "Selectable list with a detail tree per item. Items: %{id: string, title: string, symbol: optional, detail: tree}. Form drafts survive selection changes."
  def list_detail(items, opts \\ []) when is_list(items),
    do: ui(%{t: "list_detail", items: items, selection: Keyword.get(opts, :selection),
      sidebar_width: Keyword.get(opts, :sidebar_width, 180), min_height: Keyword.get(opts, :min_height, 320)}, opts)

end
