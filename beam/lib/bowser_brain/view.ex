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
    %{t: "vstack", children: children, spacing: Keyword.get(opts, :spacing, 8)}
  end

  def hstack(children, opts \\ []) when is_list(children) do
    %{t: "hstack", children: children, spacing: Keyword.get(opts, :spacing, 8)}
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
end
