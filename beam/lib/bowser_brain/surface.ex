defmodule BowserBrain.Surface do
  @moduledoc """
  Mod-owned native surfaces (ADR 0009). Show/update a floating panel with a
  view tree from BowserBrain.View; calling show/3 again with the same id
  re-renders in place — so mods just re-show on every state change.

      Surface.show(:page_tools, view, title: "Page", anchor: :right_of_main)
      Surface.close(:page_tools)

  Surfaces die with the engine; re-show on the "hello" event (or just on the
  next event you care about) to resurrect them.
  """

  alias BowserBrain.Bridge

  def show(id, view, opts \\ []) when is_map(view) do
    Bridge.cast_msg(%{
      op: "surface",
      surface: "show",
      id: to_string(id),
      # :floating (default) or :toolbar_overlay (click-through effects
      # layer riding the main window's toolbar region).
      kind: to_string(Keyword.get(opts, :kind, :floating)),
      title: Keyword.get(opts, :title, to_string(id)),
      anchor: to_string(Keyword.get(opts, :anchor, :right_of_main)),
      width: Keyword.get(opts, :width, 260),
      view: view
    })
  end

  def close(id) do
    Bridge.cast_msg(%{op: "surface", surface: "close", id: to_string(id)})
  end

  @doc "Bring a tab's window to front."
  def activate_tab(webview), do: Bridge.cast_msg(%{op: "activate_tab", webview: webview})

  @doc "Close a tab's window."
  def close_tab(webview), do: Bridge.cast_msg(%{op: "close_tab", webview: webview})
end
