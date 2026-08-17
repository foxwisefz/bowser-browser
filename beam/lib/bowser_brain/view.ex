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

  @doc "opts: event: (required), active:, symbol: (SF Symbol), indent:, payload:"
  def button(label, opts) do
    %{
      t: "button",
      label: to_string(label),
      event: to_string(Keyword.fetch!(opts, :event)),
      active: Keyword.get(opts, :active, false),
      symbol: Keyword.get(opts, :symbol),
      indent: Keyword.get(opts, :indent, 0),
      payload: Keyword.get(opts, :payload)
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

  @doc "Sends {id, value} on Enter."
  def textfield(event, opts \\ []) do
    %{
      t: "textfield",
      event: to_string(event),
      placeholder: Keyword.get(opts, :placeholder, ""),
      value: Keyword.get(opts, :value, "")
    }
  end

  def divider, do: %{t: "divider"}
  def spacer(opts \\ []), do: %{t: "spacer", min: Keyword.get(opts, :min, 0)}
  def image(symbol), do: %{t: "image", symbol: to_string(symbol)}
end
