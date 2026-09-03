defmodule BowserBrain.BudgetTest do
  use ExUnit.Case, async: false

  alias BowserBrain.Budget

  setup do
    dir = Path.join(System.tmp_dir!(), "bowser-budget-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:bowser_brain, :data_dir)
    Application.put_env(:bowser_brain, :data_dir, dir)
    BowserBrain.Store.clear("budget")
    on_exit(fn ->
      if previous, do: Application.put_env(:bowser_brain, :data_dir, previous), else: Application.delete_env(:bowser_brain, :data_dir)
      File.rm_rf!(dir)
    end)
    :ok
  end

  defmodule FollowMod do
  end

  test "spends up to the limit, then refuses without counting" do
    day = ~D[2026-09-03]
    assert :ok = Budget.take(FollowMod, "x.com", date: day, limit: 2)
    assert :ok = Budget.take(FollowMod, "x.com", date: day, limit: 2)
    assert {:error, :exhausted} = Budget.take(FollowMod, "x.com", date: day, limit: 2)
    assert Budget.used(FollowMod, "x.com", date: day) == 2
    assert Budget.remaining(FollowMod, "x.com", date: day, limit: 2) == 0
  end

  test "mod, host and day are independent buckets" do
    day = ~D[2026-09-03]
    :ok = Budget.take(FollowMod, "x.com", date: day, limit: 1)
    assert {:error, :exhausted} = Budget.take(FollowMod, "x.com", date: day, limit: 1)
    assert :ok = Budget.take(FollowMod, "youtube.com", date: day, limit: 1)
    assert :ok = Budget.take(OtherMod, "x.com", date: day, limit: 1)
    assert :ok = Budget.take(FollowMod, "x.com", date: ~D[2026-09-04], limit: 1)
  end

  test "parse_limit: owner setting or the default" do
    assert Budget.parse_limit(nil) == 30
    assert Budget.parse_limit("50") == 50
    assert Budget.parse_limit(" 7 ") == 7
    assert Budget.parse_limit("lots") == 30
    assert Budget.parse_limit("0") == 30
    assert Budget.parse_limit(12) == 12
  end
end
