# Ships as an example_mods file; compile it here so its logic stays tested.
Code.put_compiler_option(:ignore_module_conflict, true)
Code.compile_file(Path.expand("../example_mods/mod_switch.ex", __DIR__))

defmodule ModSwitchModTest do
  use ExUnit.Case, async: true

  describe "modname/1" do
    test "reads the defmodule name out of mod source" do
      assert ModSwitchMod.modname("# comment\ndefmodule EdgeDockTabs do\nend") == "EdgeDockTabs"
      assert ModSwitchMod.modname("defmodule My.Nested_Mod do") == "My.Nested_Mod"
      assert ModSwitchMod.modname("no module here") == nil
    end
  end

  describe "toggle_path/1 and enabled?/1" do
    test "off is a rename, on is the rename undone" do
      assert ModSwitchMod.toggle_path("a.css") == "a.css.off"
      assert ModSwitchMod.toggle_path("a.css.off") == "a.css"
      assert ModSwitchMod.toggle_path("dock.ex") == "dock.ex.off"
      assert ModSwitchMod.enabled?("a.css")
      refute ModSwitchMod.enabled?("a.css.off")
    end
  end

  describe "describe_source/1" do
    test "elixir leading comment" do
      assert ModSwitchMod.describe_source("# The panel directory: lists panels.\ndefmodule X do") ==
               "The panel directory: lists panels."
    end

    test "js line comment and css block comment" do
      assert ModSwitchMod.describe_source("// music resume after rolls\n(function(){})()") ==
               "music resume after rolls"

      assert ModSwitchMod.describe_source("/* Timeline-only view for x.com */\nheader {}") ==
               "Timeline-only view for x.com"
    end

    test "no comment yields nil; long lines truncate" do
      assert ModSwitchMod.describe_source("defmodule X do\nend") == nil
      long = "# " <> String.duplicate("a", 100)
      assert String.length(ModSwitchMod.describe_source(long)) <= 61
    end
  end

  describe "host_of_source/1" do
    test "reads the Mod host: declaration" do
      assert ModSwitchMod.host_of_source(~s(use BowserBrain.Mod, host: "x.com")) == "x.com"
      assert ModSwitchMod.host_of_source("use BowserBrain.Mod") == nil
    end
  end

  describe "info expansion" do
    test "the (i) button toggles a row's description open and closed" do
      state = %{active: 0, urls: %{}, info: MapSet.new()}
      ev = %{"event" => "surface", "surface" => "mods", "id" => "info", "value" => "mod|tabs.ex"}

      state = ModSwitchMod.handle_event(ev, state)
      assert MapSet.member?(state.info, "mod|tabs.ex")

      state = ModSwitchMod.handle_event(ev, state)
      refute MapSet.member?(state.info, "mod|tabs.ex")
    end
  end

  describe "parse_toggle/1" do
    test "site and mod payloads round-trip" do
      assert ModSwitchMod.parse_toggle("site|x.com|plurk.css") == {:site, "x.com", "plurk.css"}
      assert ModSwitchMod.parse_toggle("mod|edge_dock_tabs.ex") == {:mod, "edge_dock_tabs.ex"}
      assert ModSwitchMod.parse_toggle("garbage") == :error
    end
  end

  describe "edit_path/1 (✎ → ModSmith)" do
    test "maps row payloads to catalog paths, stripping .off" do
      assert ModSwitchMod.edit_path("mod|dock.ex") == "mods/dock.ex"
      assert ModSwitchMod.edit_path("mod|nav.ex.off") == "mods/nav.ex"
      assert ModSwitchMod.edit_path("site|x.com|font.css.off") == "sites/x.com/font.css"
      assert ModSwitchMod.edit_path("garbage") == nil
    end
  end

  test "toggle_payload accepts a switch map or a plain button payload" do
    assert ModSwitchMod.toggle_payload(%{"on" => false, "payload" => "mod|dock.ex"}) == "mod|dock.ex"
    assert ModSwitchMod.toggle_payload("site|x.com|a.css") == "site|x.com|a.css"
  end

  test "should_flip? is idempotent for switches and always true for plain buttons" do
    refute ModSwitchMod.should_flip?(%{"on" => true, "payload" => "mod|dock.ex"})
    assert ModSwitchMod.should_flip?(%{"on" => false, "payload" => "mod|dock.ex"})
    refute ModSwitchMod.should_flip?(%{"on" => false, "payload" => "mod|nav.ex.off"})
    assert ModSwitchMod.should_flip?(%{"on" => true, "payload" => "site|x.com|a.css.off"})
    assert ModSwitchMod.should_flip?("mod|dock.ex")
  end
end
