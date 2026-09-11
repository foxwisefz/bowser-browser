defmodule BowserBrain.ProfileOwnershipTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{ModScope, Surface}

  test "ownership survives edits and supports all source formats" do
    for ext <- [".ex", ".js", ".css"] do
      tagged = ModScope.tag("content", "work", ext)
      assert ModScope.source_profile(tagged) == "work"
      assert ModScope.source_profile(ModScope.tag(tagged, "default", ext)) == "default"
    end
    assert ModScope.source_profile("legacy source") == "default"
  end

  test "hello contains only the owning profile and other profile events are dropped" do
    hello = %{"event" => "hello", "active" => 2, "tabs" => [
      %{"id" => 1, "profile" => "default"}, %{"id" => 2, "profile" => "work"}]}
    assert %{"tabs" => [%{"id" => 1}], "webviews" => [1], "active" => 1} = ModScope.filter(hello, "default")
    assert nil == ModScope.filter(%{"event" => "tab_activated", "profile" => "work"}, "default")
    assert %{"surface" => "panel"} = ModScope.filter(%{"event" => "surface", "profile" => "work", "surface" => "profile:work:panel"}, "work")
  end

  test "same panel id in different profiles retains separate contents and ownership" do
    on_exit(fn -> Process.delete(:bowser_profile) end)
    for profile <- ["default", "work"] do
      Process.put(:bowser_profile, profile)
      Surface.show(:scope_test_panel, %{t: "text", text: profile})
    end
    Process.delete(:bowser_profile)
    entries = Enum.filter(Surface.list(), &String.ends_with?(&1.id, ":scope_test_panel"))
    assert Enum.sort(Enum.map(entries, & &1.profile)) == ["default", "work"]
    Process.put(:bowser_profile, "work")
    Surface.close(:scope_test_panel)
    Process.delete(:bowser_profile)
    assert Enum.find(Surface.list(), &(&1.id == "profile:work:scope_test_panel")).closed
    refute Enum.find(Surface.list(), &(&1.id == "profile:default:scope_test_panel")).closed
  end
end
