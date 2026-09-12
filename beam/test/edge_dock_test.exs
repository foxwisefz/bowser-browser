defmodule EdgeDockTabsTest do
  use ExUnit.Case, async: false

  defp base, do: %{tabs: %{}, order: [], active: nil}

  defp ev(state, map), do: BowserBrain.TabDeck.handle_event(map, state)

  test "native insertion order overrides event arrival order" do
    state = base()
      |> ev(%{"event" => "hello", "tabs" => [%{"id" => 1}, %{"id" => 2}], "active" => 1})
      |> ev(%{"event" => "tab_opened", "webview" => 3, "order" => [1, 3, 2]})
    assert state.order == [1, 3, 2]
  end

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
    assert ^state = BowserBrain.TabDeck.handle_event(%{"event" => "webview_closed", "webview" => 9}, state)
  end

  test "visible_order shows only the active tab's profile; unknown profile = default; no active = all" do
    state =
      base()
      |> ev(%{"event" => "tab_opened", "webview" => 1, "profile" => "default"})
      |> ev(%{"event" => "tab_opened", "webview" => 2, "profile" => "work"})
      |> ev(%{"event" => "tab_opened", "webview" => 3})
      |> ev(%{"event" => "tab_opened", "webview" => 4, "profile" => "work"})

    assert BowserBrain.TabDeck.active_profile(state) == nil
    assert BowserBrain.TabDeck.active_profile(%{state | active: 2}) == "work"
    assert BowserBrain.TabDeck.active_profile(%{state | active: 3}) == "default"
    assert BowserBrain.TabDeck.visible_order(state) == [1, 2, 3, 4]
    assert BowserBrain.TabDeck.visible_order(%{state | active: 2}) == [2, 4]
    assert BowserBrain.TabDeck.visible_order(%{state | active: 3}) == [1, 3]
  end
end
