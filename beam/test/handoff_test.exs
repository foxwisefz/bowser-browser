defmodule BowserBrain.HandoffTest do
  use ExUnit.Case, async: true
  alias BowserBrain.Handoff

  test "portable snapshots preserve nested data and reject VM resources" do
    assert Handoff.portable?(%{tabs: %{1 => "https://example.test"}, values: MapSet.new([:a]), queue: :queue.from_list([1, 2])})
    refute Handoff.portable?(%{nested: [self()]})
    refute Handoff.portable?(%{timer: make_ref()})
    refute Handoff.portable?([fn -> :ok end])
    refute Handoff.portable?([1 | self()])
  end

  defmodule LegacyMod do
    use BowserBrain.Mod
  end
  defmodule DataMod do
    use BowserBrain.Mod, handoff: true
  end
  test "mods must explicitly declare the stronger lifecycle contract" do
    refute LegacyMod.__bowser_handoff__()
    assert DataMod.__bowser_handoff__()
  end
  test "owned UI checkpoints preserve order and payload but reject unknown owners" do
    entries = [{self(), make_ref(), %{background: "#123456"}}]
    for service <- [BowserBrain.ShellTheme, BowserBrain.Toolbars] do
      snapshot = Handoff.checkpoint_state(service, entries, %{self() => DataMod})
      assert snapshot == [{DataMod, %{background: "#123456"}}]
      assert Handoff.portable?(snapshot)
      assert_raise KeyError, fn -> Handoff.checkpoint_state(service, entries, %{}) end
      assert_raise KeyError, fn -> Handoff.restore_owned_entries(snapshot, %{}) end
      [{pid, monitor, payload}] = Handoff.restore_owned_entries(snapshot, %{DataMod => self()})
      assert pid == self()
      assert is_reference(monitor)
      assert payload == %{background: "#123456"}
      Process.demonitor(monitor, [:flush])
    end
  end

end
