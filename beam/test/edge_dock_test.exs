# Ships as an example_mods file (hot-loaded from ~/.bowser/mods in
# production); compile it here so its event logic stays tested.
Code.put_compiler_option(:ignore_module_conflict, true)
Code.compile_file(Path.expand("../example_mods/edge_dock_tabs.ex", __DIR__))

defmodule EdgeDockTabsTest do
  use ExUnit.Case, async: false

  defp base, do: %{tabs: %{}, order: [], active: nil}

  defp ev(state, map), do: EdgeDockTabs.handle_event(map, state)

  test "closed tabs leave the dock — no phantom icons (bowser-browser-55l)" do
    state =
      base()
      |> ev(%{"event" => "tab_opened", "webview" => 1})
      |> ev(%{"event" => "tab_opened", "webview" => 2})
      |> ev(%{"event" => "tab_activated", "webview" => 2})
      |> ev(%{"event" => "webview_closed", "webview" => 2})

    assert state.order == [1]
    refute Map.has_key?(state.tabs, 2)
    # The closed tab was active: don't keep pointing at a ghost.
    assert state.active == nil
  end

  test "closing a background tab keeps the active one" do
    state =
      base()
      |> ev(%{"event" => "tab_opened", "webview" => 1})
      |> ev(%{"event" => "tab_opened", "webview" => 2})
      |> ev(%{"event" => "tab_activated", "webview" => 1})
      |> ev(%{"event" => "webview_closed", "webview" => 2})

    assert state.order == [1]
    assert state.active == 1
  end

  test "closing an unknown webview is a no-op" do
    state = base() |> ev(%{"event" => "tab_opened", "webview" => 1})
    assert ^state = EdgeDockTabs.handle_event(%{"event" => "webview_closed", "webview" => 9}, state)
  end

  test "visible_order shows only the active tab's profile; unknown profile = default; no active = all" do
    state =
      base()
      |> ev(%{"event" => "tab_opened", "webview" => 1, "profile" => "default"})
      |> ev(%{"event" => "tab_opened", "webview" => 2, "profile" => "work"})
      |> ev(%{"event" => "tab_opened", "webview" => 3})
      |> ev(%{"event" => "tab_opened", "webview" => 4, "profile" => "work"})

    assert EdgeDockTabs.visible_order(state) == [1, 2, 3, 4]
    assert EdgeDockTabs.visible_order(%{state | active: 2}) == [2, 4]
    assert EdgeDockTabs.visible_order(%{state | active: 3}) == [1, 3]
  end
end
