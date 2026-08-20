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

  describe "parse_toggle/1" do
    test "site and mod payloads round-trip" do
      assert ModSwitchMod.parse_toggle("site|x.com|plurk.css") == {:site, "x.com", "plurk.css"}
      assert ModSwitchMod.parse_toggle("mod|edge_dock_tabs.ex") == {:mod, "edge_dock_tabs.ex"}
      assert ModSwitchMod.parse_toggle("garbage") == :error
    end
  end
end
