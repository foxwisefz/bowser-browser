defmodule BowserBrain.AgentPortStoreTest do
  use ExUnit.Case, async: false

  alias BowserBrain.AgentPort

  setup do
    dir = Path.join(System.tmp_dir!(), "bowser-apstore-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:bowser_brain, :data_dir)
    Application.put_env(:bowser_brain, :data_dir, dir)
    on_exit(fn ->
      if previous, do: Application.put_env(:bowser_brain, :data_dir, previous), else: Application.delete_env(:bowser_brain, :data_dir)
      File.rm_rf!(dir)
    end)
    :ok
  end

  test "store_put seeds and store_get reads a mod's Store by module name" do
    BowserBrain.Store.clear("FollowMod")
    assert %{ok: true} = AgentPort.dispatch(%{"tool" => "store_put", "args" => %{"mod" => "FollowMod", "key" => "follows", "value" => %{"alice" => %{"at" => 1}}}})
    assert %{ok: true, value: %{"alice" => %{"at" => 1}}} = AgentPort.dispatch(%{"tool" => "store_get", "args" => %{"mod" => "FollowMod", "key" => "follows"}})
    assert %{ok: true, all: %{"follows" => _}} = AgentPort.dispatch(%{"tool" => "store_get", "args" => %{"mod" => "FollowMod"}})
    # what the mod itself sees, via its __MODULE__
    assert BowserBrain.Store.get(FollowMod, "follows") == %{"alice" => %{"at" => 1}}
  end

  test "missing mod/key are refused" do
    assert %{ok: false} = AgentPort.dispatch(%{"tool" => "store_get", "args" => %{}})
    assert %{ok: false} = AgentPort.dispatch(%{"tool" => "store_put", "args" => %{"mod" => "X"}})
  end
end
