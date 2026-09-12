defmodule BowserBrain.HandoffCheckpointTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias BowserBrain.HandoffCheckpoint, as: Checkpoint

  test "preserves portable ETF shapes, including improper lists and bitstrings" do
    value = %{queue: :queue.from_list([1, 2]), set: MapSet.new([:a]), values: {1.5, -42, 1 <<< 100},
              list: [1 | :tail], text: "note", bits: <<3::2>>}
    for options <- [[], [:compressed]] do
      assert Checkpoint.decode!(:erlang.term_to_binary(value, options)) == value
    end
  end

  test "admits a runtime atom that is absent from the receiver without executing code" do
    name = "handoff_runtime_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    payload = <<119, byte_size(name), name::binary>>
    assert Checkpoint.decode!(<<131, 80, byte_size(payload)::32, :zlib.compress(payload)::binary>>)
           |> Atom.to_string() == name
  end

  test "rejects executable terms, resources and trailing bytes before admitting names" do
    name = "handoff_rejected_#{System.unique_integer([:positive])}"
    atom = <<119, byte_size(name), name::binary>>
    for value <- [self(), make_ref(), fn -> :ok end, &Enum.map/2] do
      <<131, resource::binary>> = :erlang.term_to_binary(value)
      assert_raise ArgumentError, fn -> Checkpoint.decode!(<<131, 104, 2, atom::binary, resource::binary>>) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
    assert_raise MatchError, fn -> Checkpoint.decode!(<<131, atom::binary, 106>>) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "bounds compressed expansion even with a false declared size" do
    huge = :zlib.compress(:binary.copy(<<0>>, 8_000_001))
    assert_raise ArgumentError, fn -> Checkpoint.decode!(<<131, 80, 8_000_001::32, huge::binary>>) end
    assert_raise ArgumentError, fn -> Checkpoint.decode!(<<131, 80, 10::32, huge::binary>>) end
    assert_raise ErlangError, fn -> Checkpoint.decode!(<<131, 80, 10::32, 1, 2, 3>>) end
  end

  test "bounds fresh atom admission and nesting before interning anything" do
    prefix = "handoff_budget_#{System.unique_integer([:positive])}_"
    atoms = for i <- 1..1025 do
      name = prefix <> Integer.to_string(i)
      <<119, byte_size(name), name::binary>>
    end
    assert_raise ArgumentError, fn ->
      Checkpoint.decode!(IO.iodata_to_binary([<<131, 108, 1025::32>>, atoms, <<106>>]))
    end
    assert_raise ArgumentError, fn -> String.to_existing_atom(prefix <> "1") end
    assert_raise ArgumentError, fn -> Checkpoint.decode!(<<131>> <> :binary.copy(<<104, 1>>, 258) <> <<106>>) end
  end
end
