defmodule BowserBrain.FollowFlywheelHandoffTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{Handoff, Store, Surface}

  Code.compile_file(Path.expand("../example_mods/follow_flywheel.ex", __DIR__))

  setup do
    Store.clear(FollowFlywheel)
    on_exit(fn ->
      Application.delete_env(:bowser_brain, :handoff_mod_states)
      for {pid, _} <- Registry.lookup(BowserBrain.ModRegistry, FollowFlywheel), do: GenServer.stop(pid)
      Store.clear(FollowFlywheel)
    end)
    :ok
  end

  test "checkpoint restores without init or duplicate work and accepts a delayed page response" do
    assert FollowFlywheel.__bowser_handoff__()
    record = %{"handle" => "fixture", "status" => "pending", "confirmed" => false, "followed_at" => 100}
    Store.put(FollowFlywheel, "follows", %{"123" => record})
    Store.put(FollowFlywheel, "last_sweep", 123456)
    {:ok, old} = FollowFlywheel.start_link([])
    :sys.replace_state(old, fn _ -> %{wv: 73} end)
    panel_before = Surface.list()
    snapshot = %{mod: :sys.get_state(old), store: :sys.get_state(Store)}
    assert Handoff.portable?(snapshot)
    restored = snapshot |> :erlang.term_to_binary() |> :erlang.binary_to_term([:safe])
    GenServer.stop(old)
    :sys.replace_state(Store, fn _ -> restored.store end)
    Application.put_env(:bowser_brain, :handoff_mod_states, %{FollowFlywheel => restored.mod})
    {:ok, replacement} = FollowFlywheel.start_link([])
    Application.delete_env(:bowser_brain, :handoff_mod_states)
    assert :sys.get_state(replacement) == %{wv: 73}
    assert Store.get(FollowFlywheel, "follows") == %{"123" => record}
    assert Store.get(FollowFlywheel, "last_sweep") == 123456
    assert Surface.list() == panel_before
    assert Process.info(replacement, :messages) == {:messages, []}

    # A fixture response only: this test never calls X or follows an account.
    send(replacement, {:browser_event, %{"event" => "page", "profile" => "default",
      "url" => "https://x.com/fixture", "webview" => 73,
      "payload" => %{"kind" => "ff_api", "op" => "follow", "tag" => "follow:123", "status" => 200}}})
    assert :sys.get_state(replacement) == %{wv: 73}
    assert Store.get(FollowFlywheel, "follows")["123"]["confirmed"]
    assert Store.get(FollowFlywheel, "last_sweep") == 123456
  end
end
