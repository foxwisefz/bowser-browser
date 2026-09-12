defmodule BowserBrain.TabDeck do
  use BowserBrain.CoreFeature

  import BowserBrain.View

  # Left-edge, mostly-hidden dock of tab favicons with proximity magnification.
  # Replaces the native tab strip (Chrome.hide_tab_bar). Click an icon to focus
  # that tab.

  def initial_state() do
    %{tabs: %{}, order: [], active: nil}
  end

  # Full tab snapshot on connect — rebuild from scratch (also prunes closed tabs).
  def handle_event(%{"event" => "hello"} = ev, state) do
    BowserBrain.Chrome.hide_tab_bar()
    base = %{state | tabs: %{}, order: []}

    state =
      ev
      |> Map.get("tabs", [])
      |> Enum.reduce(base, fn t, acc ->
        case Map.get(t, "id") do
          nil ->
            acc

          wv ->
            acc = put_tab(acc, wv, favicon: Map.get(t, "favicon"), title: Map.get(t, "title"), profile: Map.get(t, "profile"))
            acc
        end
      end)

    state = %{state | active: Map.get(ev, "active", state.active)}
    render(state)
  end

  def handle_event(%{"event" => "tab_opened", "webview" => wv} = ev, state) do
    state |> put_tab(wv, profile: ev["profile"]) |> apply_order(ev["order"]) |> render()
  end

  def handle_event(%{"event" => "tab_activated", "webview" => wv}, state) do
    %{state | active: wv} |> put_tab(wv, []) |> render()
  end

  # Closed tabs leave the dock immediately — without this every ⌘W left a
  # phantom icon until the next engine roll (bowser-browser-55l).
  def handle_event(%{"event" => "webview_closed", "webview" => wv}, state) do
    if Map.has_key?(state.tabs, wv) or wv in state.order do
      %{
        state
        | tabs: Map.delete(state.tabs, wv),
          order: List.delete(state.order, wv),
          active: if(state.active == wv, do: nil, else: state.active)
      }
      |> render()
    else
      state
    end
  end

  def handle_event(%{"event" => "favicon_changed", "webview" => wv, "path" => path}, state) do
    state |> put_tab(wv, favicon: path) |> render()
  end

  def handle_event(%{"event" => "title_changed"} = ev, state) do
    case Map.get(ev, "webview", state.active) do
      nil -> state
      wv -> state |> put_tab(wv, title: Map.get(ev, "title")) |> render()
    end
  end

  # Dock click -> focus that tab. value is the item id we set (webview id).
  def handle_event(
        %{"event" => "surface", "surface" => "edge_dock", "id" => "select", "value" => v},
        state
      ) do
    case Enum.find(state.order, fn wv -> to_string(wv) == to_string(v) end) do
      nil ->
        state

      wv ->
        focus_tab(wv)
        render(%{state | active: wv})
    end
  end

  def handle_event(%{"event" => "mod_reloaded"}, state) do
    BowserBrain.Chrome.hide_tab_bar()
    render(state)
  end

  def handle_event(_ev, state), do: state

  # -- helpers ---------------------------------------------------------------

  @doc """
  The dock shows only the ACTIVE window's profile: tabs whose profile is the
  active tab's (a tab with no recorded profile counts as default). With no
  active tab yet, everything shows. Public for tests.
  """
  def visible_order(state) do
    case active_profile(state) do
      nil -> state.order
      active_profile -> Enum.filter(state.order, &(profile_of(state, &1) == active_profile))
    end
  end

  def active_profile(state), do: state.active && profile_of(state, state.active)

  defp profile_of(state, wv), do: Map.get(Map.get(state.tabs, wv, %{}), :profile) || "default"

  defp put_tab(state, wv, attrs) do
    tab = Map.get(state.tabs, wv, %{favicon: nil, title: nil})

    tab =
      Enum.reduce(attrs, tab, fn
        {_k, nil}, acc -> acc
        {k, val}, acc -> Map.put(acc, k, val)
      end)

    order = if wv in state.order, do: state.order, else: state.order ++ [wv]
    %{state | tabs: Map.put(state.tabs, wv, tab), order: order}
  end

  defp apply_order(state, order) when is_list(order) do
    known = Enum.filter(Enum.uniq(order), &Map.has_key?(state.tabs, &1))
    %{state | order: known ++ (state.order -- known)}
  end
  defp apply_order(state, _), do: state

  defp render(state) do
    # The header identifies the active profile; tab artwork needs no repeated badge.
    profiles = BowserBrain.Profiles.list()
    rank = profiles |> Enum.map(& &1["id"]) |> Enum.with_index() |> Map.new()

    grouped =
      Enum.sort_by(visible_order(state), fn wv ->
        Map.get(rank, Map.get(Map.get(state.tabs, wv, %{}), :profile) || "default", 99)
      end)

    items =
      Enum.map(grouped, fn wv ->
        tab = Map.get(state.tabs, wv, %{favicon: nil, title: nil})

        base = %{
          id: to_string(wv),
          active: wv == state.active,
          title: tab.title || "Tab #{wv}"
        }


        case tab.favicon do
          nil -> Map.put(base, :symbol, "globe")
          path -> Map.put(base, :path, path)
        end
      end)

    BowserBrain.Surface.show(
      :edge_dock,
      magnify_strip(items, size: 32, spacing: 8, magnify: 1.4, event: "select",
        header: profile_header(active_profile(state)), header_height: 82, header_outside: true, chrome: "notch")
      |> Map.put(:profile_id, active_profile(state)),
      title: "Tabs",
      kind: :edge,
      edge: :left,
      peek: 3,
      attach: :screen,
      width: 48
    )

    state
  end

  def profile_header(nil), do: nil
  def profile_header(id) do
    profile = Enum.find(BowserBrain.Profiles.list(), &(&1["id"] == id)) || %{}
    name = if id == "default", do: "Default", else: profile["name"] || id
    profile_avatar(id, size: 18, badge: true, help: "Profile: " <> name)
  end

  defp focus_tab(wv) do
    BowserBrain.Surface.activate_tab(wv)
  end
end
