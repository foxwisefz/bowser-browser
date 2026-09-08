defmodule PanelsModTest do
  use ExUnit.Case, async: true

  defp entry(id, title, owner \\ nil), do: %{id: id, title: title, owner: owner}

  test "unique titles pass through untouched" do
    titles = BowserBrain.PanelMenu.menu_titles([entry("a", "Reader"), entry("b", "Tabs")])
    assert titles == %{"a" => "Reader", "b" => "Tabs"}
  end

  test "colliding titles get the owner appended" do
    titles =
      BowserBrain.PanelMenu.menu_titles([
        entry("edge_dock", "Tabs", "EdgeDockTabs"),
        entry("tabs", "Tabs", "TabsMod")
      ])

    assert titles["edge_dock"] == "Tabs (EdgeDockTabs)"
    assert titles["tabs"] == "Tabs (TabsMod)"
  end

  test "collisions are case-insensitive and fall back to the id without an owner" do
    titles = BowserBrain.PanelMenu.menu_titles([entry("x", "tabs"), entry("y", "Tabs", "SomeMod")])
    assert titles["x"] == "tabs (x)"
    assert titles["y"] == "Tabs (SomeMod)"
  end

  test "visible/1 keeps panels and drops Settings-window sections" do
    entries = [%{id: "dock", kind: "edge", title: "Tabs"}, %{id: "settings", kind: "settings", title: "General"}, %{id: "ff", kind: "floating", title: "Follow"}]
    assert Enum.map(BowserBrain.PanelMenu.visible(entries), & &1.id) == ["dock", "ff"]
  end
end
