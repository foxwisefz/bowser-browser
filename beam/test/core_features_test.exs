defmodule BowserBrain.CoreFeaturesTest do
  use ExUnit.Case, async: false

  test "the three features are named core services, not dynamic mods" do
    children = Supervisor.which_children(BowserBrain.Supervisor)
    for module <- [BowserBrain.TabDeck, BowserBrain.ModControls, BowserBrain.PanelMenu] do
      assert is_pid(Process.whereis(module))
      assert Enum.any?(children, fn {id, _, _, _} -> id == module end)
      refute function_exported?(module, :__bowser_mod__, 0)
      assert Registry.lookup(BowserBrain.ModRegistry, module) == []
      assert BowserBrain.Handoff.portable?(:sys.get_state(module))
    end
  end

  test "legacy sources are skipped and hidden from the editable mod catalog" do
    dir = Path.join(System.tmp_dir!(), "core-legacy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    for name <- ["EdgeDockTabs", "ModSwitchMod", "PanelsMod", "MediaWarmMod"] do
      path = Path.join(dir, "#{name}.ex")
      File.write!(path, "defmodule #{name} do\nend")
      assert BowserBrain.LegacyMods.superseded?(path)
    end
    File.write!(Path.join(dir, "personal.ex"), "defmodule PersonalFixture do\nend")
    assert [%{path: "mods/personal.ex"}] = BowserBrain.ModCatalog.catalog(dir, Path.join(dir, "sites"))
  end

  test "panel menu responds to registry changes without a polling timer" do
    BowserBrain.Surface.show("core-menu-test", %{t: "text", text: "fixture"}, title: "Core test")
    # Surface notifies from its callback before replying; querying both servers
    # after it ensures the menu has processed the registry-change notification.
    :sys.get_state(BowserBrain.Surface)
    menu = :sys.get_state(BowserBrain.PanelMenu)
    assert menu.menu["panel:core-menu-test"].checked
    assert {:ok, :hidden} = BowserBrain.Surface.toggle("core-menu-test")
    menu = :sys.get_state(BowserBrain.PanelMenu)
    refute menu.menu["panel:core-menu-test"].checked
  end
end
