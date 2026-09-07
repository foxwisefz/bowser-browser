defmodule BowserBrain.EngineTest do
  use ExUnit.Case, async: true

  alias BowserBrain.Engine

  test "explicit app quit disarms supervision before backend shutdown" do
    state = %{port: nil, os_pid: 123, enabled: true}
    {:reply, :ok, quitting} = Engine.handle_call(:prepare_quit, self(), state)
    assert quitting.os_pid == nil
    assert quitting.enabled == false
    assert {:noreply, ^quitting} = Engine.handle_info(:check, quitting)
    assert :ok = Engine.terminate(:shutdown, quitting)
  end

  describe "check_action/3" do
    test "a live port with a newer binary on disk rolls" do
      assert Engine.check_action(true, true, true) == :roll
      assert Engine.check_action(true, true, false) == :roll
    end

    test "a live port with a current binary keeps" do
      assert Engine.check_action(true, false, false) == :keep
    end

    test "no port but a connected bridge keeps (hand-started browser)" do
      assert Engine.check_action(false, false, true) == :keep
      # A hand-started browser is not ours to roll, even with a newer binary.
      assert Engine.check_action(false, true, true) == :keep
    end

    test "no port and no bridge spawns" do
      assert Engine.check_action(false, false, false) == :spawn
      assert Engine.check_action(false, true, false) == :spawn
    end
  end

  describe "respawn_delay/2" do
    test "respawns nearly instantly in the normal case" do
      # Last spawn long ago: the window-gone gap should be as short as the
      # OS allows (bowser-browser-r48).
      assert Engine.respawn_delay(1_000_000, 2_000_000) == 100
    end

    test "backs off when the last spawn was seconds ago — crash-loop guard" do
      now = 2_000_000
      assert Engine.respawn_delay(now - 5_000, now) == 2_000
      assert Engine.respawn_delay(now - 9_999, now) == 2_000
      assert Engine.respawn_delay(now - 10_001, now) == 100
    end

    test "no previous spawn: instant" do
      assert Engine.respawn_delay(0, 2_000_000) == 100
    end
  end

  describe "roll_kill_args/1" do
    test "rolls with TERM so the wrapper's trap can forward to the browser" do
      # kill -9 here orphans the browser: SIGKILL skips the wrapper's trap,
      # the child and watcher survive holding the port pipe, and the brain
      # loops 'rolling respawn' on a dead pid forever (bowser-browser-p7l).
      assert Engine.roll_kill_args(21481) == ["-TERM", "21481"]
    end
  end

  describe "user quit" do
    test "a clean exit disables spawning and the check loop stops" do
      port = make_ref()
      state = %{port: port, os_pid: 123, enabled: true}
      assert {:noreply, quit} = BowserBrain.Engine.handle_info({port, {:exit_status, 0}}, state)
      assert quit.enabled == false and quit.port == nil
      assert {:noreply, ^quit} = BowserBrain.Engine.handle_info(:check, quit)
      refute_receive :check, 100
    end

    test "a dirty exit still schedules a respawn" do
      port = make_ref()
      state = %{port: port, os_pid: 1, enabled: true, last_spawn_at: 0}
      assert {:noreply, s} = BowserBrain.Engine.handle_info({port, {:exit_status, 133}}, state)
      assert s.enabled == true and s.port == nil
    end
  end
end
