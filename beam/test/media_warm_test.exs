# The mod ships as an example_mods file (hot-loaded from ~/.bowser/mods in
# production); compile it here so its pure decision logic stays under test.
Code.put_compiler_option(:ignore_module_conflict, true)
Code.compile_file(Path.expand("../example_mods/media_warm.ex", __DIR__))

defmodule MediaWarmModTest do
  use ExUnit.Case, async: true

  @now 1_787_000_000_000

  defp snap(paused, age_ms) do
    JSON.encode!(%{t: 431.5, paused: paused, at: @now - age_ms})
  end

  test "fresh snapshot of playing media is resumable" do
    assert MediaWarmMod.resumable?(snap(false, 5_000), @now)
  end

  test "paused media is not resumable — nothing to bring back" do
    refute MediaWarmMod.resumable?(snap(true, 5_000), @now)
  end

  test "stale snapshot (over the 2min window) is not resumable" do
    refute MediaWarmMod.resumable?(snap(false, 121_000), @now)
  end

  test "just inside the window is resumable" do
    assert MediaWarmMod.resumable?(snap(false, 119_000), @now)
  end

  test "no snapshot / garbage is not resumable" do
    refute MediaWarmMod.resumable?(nil, @now)
    refute MediaWarmMod.resumable?("not json", @now)
    refute MediaWarmMod.resumable?(JSON.encode!(%{wrong: "shape"}), @now)
  end
end
