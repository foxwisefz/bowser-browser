# Proving mod for the tab model (5y4): vertical tabs, nested by which tab
# opened which — rendered as a native floating palette. The tree lives in
# this process's state, so it survives engine kills better than any native
# tab strip could.
defmodule TabsMod do
  use BowserBrain.Mod
  import BowserBrain.View
  alias BowserBrain.Surface

  def init_mod(_opts) do
    render(%{tabs: %{}, order: [], active: nil})
  end

  def handle_event(%{"event" => "hello"} = event, state) do
    tabs =
      for %{"id" => id} = tab <- Map.get(event, "tabs", []), into: %{} do
        {id, %{title: tab["url"] || "tab #{id}", opener: nil}}
      end

    render(%{state | tabs: tabs, order: tabs |> Map.keys() |> Enum.sort()})
  end

  def handle_event(%{"event" => "tab_opened", "webview" => id} = event, state) do
    tab = %{title: "new tab", opener: event["opener"]}
    render(%{state | tabs: Map.put(state.tabs, id, tab), order: state.order ++ [id]})
  end

  def handle_event(%{"event" => "webview_closed", "webview" => id}, state) do
    render(%{state | tabs: Map.delete(state.tabs, id), order: List.delete(state.order, id)})
  end

  def handle_event(%{"event" => "title_changed", "webview" => id, "title" => title}, state)
      when title != "" do
    case state.tabs[id] do
      nil -> state
      tab -> render(%{state | tabs: Map.put(state.tabs, id, %{tab | title: title})})
    end
  end

  def handle_event(%{"event" => "tab_activated", "webview" => id}, state) do
    if state.active == id, do: state, else: render(%{state | active: id})
  end

  def handle_event(
        %{"event" => "surface", "surface" => "tabs", "id" => "activate", "value" => id},
        state
      ) do
    Surface.activate_tab(trunc(id))
    state
  end

  def handle_event(_event, state), do: state

  defp render(state) do
    rows =
      state.order
      |> roots(state.tabs)
      |> Enum.flat_map(&rows_for(&1, 0, state))

    Surface.show(:tabs, vstack([text("Tabs", style: :title) | rows]),
      title: "Tabs",
      anchor: :left_of_main,
      width: 230
    )

    state
  end

  defp roots(order, tabs) do
    Enum.filter(order, fn id ->
      opener = tabs[id].opener
      opener == nil or not Map.has_key?(tabs, opener)
    end)
  end

  defp rows_for(id, depth, state) do
    tab = state.tabs[id]
    children = Enum.filter(state.order, fn other -> state.tabs[other].opener == id end)

    [
      button(truncate(tab.title),
        event: :activate,
        payload: id,
        active: state.active == id,
        indent: depth * 14
      )
      | Enum.flat_map(children, &rows_for(&1, depth + 1, state))
    ]
  end

  defp truncate(title) do
    if String.length(title) > 28, do: String.slice(title, 0, 27) <> "…", else: title
  end
end
