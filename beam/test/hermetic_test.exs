defmodule HermeticTest do
  # The fence that keeps `mix test` away from the live browser
  # (bowser-browser-is4). If any of these fail, tests can reach the OWNER's
  # real engine again — a test run once navigated all real tabs to fixture
  # URLs. Guards live in config/config.exs, which loads BEFORE app boot.
  use ExUnit.Case, async: true

  test "test env never connects to the live engine" do
    assert Application.get_env(:bowser_brain, :connect_bridge) == false
    refute BowserBrain.Bridge.connected?()
  end

  test "test env never spawns or rolls the engine" do
    assert Application.get_env(:bowser_brain, :spawn_engine) == false
    assert :sys.get_state(BowserBrain.Engine).enabled == false
  end

  test "test env never compiles the owner's live mods or watches their sites" do
    assert Application.get_env(:bowser_brain, :load_user_mods) == false
    assert Application.get_env(:bowser_brain, :watch_lib) == false
    assert Application.get_env(:bowser_brain, :watch_sites) == false
  end

  test "session persistence points at tmp, never ~/.bowser" do
    for key <- [:session_path, :settings_path, :modsmith_sessions_path, :modsmith_workspace_path] do
      path = Application.get_env(:bowser_brain, key)
      assert is_binary(path)
      refute String.contains?(path, ".bowser")
    end
  end
end
