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
end
