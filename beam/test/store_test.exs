defmodule BowserBrain.StoreTest do
  # async: false — swaps the app-wide data_dir.
  use ExUnit.Case, async: false

  alias BowserBrain.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "bowser-store-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:bowser_brain, :data_dir)
    Application.put_env(:bowser_brain, :data_dir, dir)

    on_exit(fn ->
      if previous, do: Application.put_env(:bowser_brain, :data_dir, previous), else: Application.delete_env(:bowser_brain, :data_dir)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  defmodule FollowMod do
  end

  test "put/get round-trips JSON-shaped values with string keys", %{dir: dir} do
    Store.clear(FollowMod)
    assert Store.get(FollowMod, "follows", %{}) == %{}
    assert :ok = Store.put(FollowMod, "follows", %{"alice" => %{"at" => 1, "back" => nil}})
    assert Store.get(FollowMod, :follows) == %{"alice" => %{"at" => 1, "back" => nil}}
    assert File.exists?(Path.join(dir, "BowserBrain.StoreTest.FollowMod.json"))
  end

  test "survives a Store process restart (it is the file that remembers)" do
    Store.clear(FollowMod)
    :ok = Store.put(FollowMod, "n", 42)
    pid = Process.whereis(Store)
    GenServer.stop(Store)
    wait_until(fn -> Process.whereis(Store) not in [nil, pid] end)
    assert Store.get(FollowMod, "n") == 42
  end

  test "update, delete, all" do
    Store.clear(FollowMod)
    assert {:ok, 1} = Store.update(FollowMod, "count", 0, &(&1 + 1))
    assert {:ok, 2} = Store.update(FollowMod, "count", 0, &(&1 + 1))
    :ok = Store.put(FollowMod, "other", "x")
    assert Store.all(FollowMod) == %{"count" => 2, "other" => "x"}
    :ok = Store.delete(FollowMod, "other")
    assert Store.all(FollowMod) == %{"count" => 2}
  end

  test "a value JSON cannot take is refused and the file is untouched" do
    Store.clear(FollowMod)
    :ok = Store.put(FollowMod, "ok", 1)
    assert {:error, _} = Store.put(FollowMod, "bad", {:tuple, self()})
    assert Store.all(FollowMod) == %{"ok" => 1}
  end

  test "scopes are file-safe and mods are isolated" do
    assert Store.scope(BowserBrain.StoreTest.FollowMod) == "BowserBrain.StoreTest.FollowMod"
    assert Store.scope("weird name/../x") == "weird_name_.._x"
    Store.clear("a")
    Store.clear("b")
    :ok = Store.put("a", "k", 1)
    assert Store.get("b", "k") == nil
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(20); wait_until(fun, tries - 1)
    end
  end
end
