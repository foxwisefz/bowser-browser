defmodule BowserBrain.ModUpgradeTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{Loader, ModRegistry}
  setup do
    path = Path.join(System.tmp_dir!(), "upgrade-#{System.unique_integer([:positive])}.ex")
    on_exit(fn ->
      for {pid, _} <- Registry.lookup(ModRegistry, UpgradeFixture), do: DynamicSupervisor.terminate_child(BowserBrain.ModSupervisor, pid)
      File.rm(path)
      :code.purge(UpgradeFixture)
      :code.delete(UpgradeFixture)
    end)
    %{path: path}
  end
  defp source(version, migration) do
    """
    defmodule UpgradeFixture do
      use BowserBrain.Mod
      def state_version, do: #{version}
      def init_mod(_), do: %{count: 3}
      def handle_event(%{"event" => "increment"}, state), do: Map.update!(state, :count, &(&1 + 1))
      def handle_event(_, state), do: state
      #{migration}
    end
    """
  end
  test "migrates an existing process; rejection and partial compile failure preserve old code and state", %{path: path} do
    File.write!(path, source(0, ""))
    assert %{ok: true} = Loader.load_now(path)
    [{pid, _}] = Registry.lookup(ModRegistry, UpgradeFixture)
    File.write!(path, source(1, "def migrate_state(0, s), do: {:ok, Map.put(s, :label, :ready)}\ndef migrate_state(1, s), do: {:ok, s}"))
    assert %{ok: true} = Loader.load_now(path)
    assert %{count: 3, label: :ready} = :sys.get_state(pid)
    assert [{^pid, _}] = Registry.lookup(ModRegistry, UpgradeFixture)
    File.write!(path, source(2, "def migrate_state(_, _), do: {:error, :nope}"))
    assert %{ok: false} = Loader.load_now(path)
    assert UpgradeFixture.state_version() == 1
    send(pid, {:browser_event, %{"event" => "increment"}})
    assert %{count: 4, label: :ready} = :sys.get_state(pid)
    File.write!(path, source(3, "") <> "\ndefmodule BrokenUpgrade do missing_macro() end")
    assert %{ok: false} = Loader.load_now(path)
    assert UpgradeFixture.state_version() == 1
    assert %{count: 4, label: :ready} = :sys.get_state(pid)
  end
  test "events queued during migration are processed once after resume", %{path: path} do
    File.write!(path, source(0, "")); assert %{ok: true} = Loader.load_now(path)
    [{pid, _}] = Registry.lookup(ModRegistry, UpgradeFixture)
    File.write!(path, source(1, "def migrate_state(_, s) do Process.sleep(250); {:ok, Map.put(s, :ready, true)} end"))
    task = Task.async(fn -> Loader.load_now(path) end)
    assert Enum.reduce_while(1..150, false, fn _, _ ->
      {:status, _, _, [_, status | _]} = :sys.get_status(pid)
      if status == :suspended, do: {:halt, true}, else: (Process.sleep(10); {:cont, false})
    end)
    for _ <- 1..20, do: send(pid, {:browser_event, %{"event" => "increment"}})
    assert %{ok: true} = Task.await(task)
    assert %{count: 23, ready: true} = :sys.get_state(pid)
  end
  test "validation rejects before activation", %{path: path} do
    File.write!(path, source(0, "")); assert %{ok: true} = Loader.load_now(path)
    File.write!(path, source(0, "def validate_state(_), do: {:error, :bad}"))
    assert %{ok: false} = Loader.load_now(path)
    assert UpgradeFixture.validate_state(%{}) == :ok
    [{pid, _}] = Registry.lookup(ModRegistry, UpgradeFixture)
    assert %{count: 3} = :sys.get_state(pid)
  end
end
