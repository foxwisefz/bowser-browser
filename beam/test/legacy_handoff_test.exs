defmodule BowserBrain.LegacyHandoffTest do
  use ExUnit.Case, async: false
  alias BowserBrain.Handoff

  for name <- ~w(hello toolbar_dance twitter_nav tabs youtube_dl) do
    Code.compile_file(Path.expand("../example_mods/#{name}.ex", __DIR__))
  end

  test "audited mods restore data without initialization, reinjection or rendering" do
    before = Map.new([BowserBrain.Surface, BowserBrain.UserContent], &{&1, :sys.get_state(&1)})
    for module <- [HelloMod, ToolbarDanceMod, TwitterNavMod, TabsMod] do
      assert module.__bowser_handoff__()
      # Deliberately not init_mod's state: restoration must keep it exactly.
      saved = %{audit_marker: [1, "retained", %{playing: true}]}
      Application.put_env(:bowser_brain, :handoff_mod_states, %{module => saved})
      try do
        {:ok, pid} = module.start_link([])
        try do
          assert :sys.get_state(pid) == saved
          assert Handoff.portable?(:sys.get_state(pid))
          assert Process.info(pid, :messages) == {:messages, []}
        after
          GenServer.stop(pid)
        end
      after
        Application.delete_env(:bowser_brain, :handoff_mod_states)
      end
    end
    assert Map.new(Map.keys(before), &{&1, :sys.get_state(&1)}) == before
  end

  test "preflight reports every incompatible mod and keeps downloader out" do
    refute YoutubeDlMod.__bowser_handoff__()
    assert Handoff.incompatible_mods([HelloMod, String, YoutubeDlMod, TabsMod]) == [String, YoutubeDlMod]
  end
end
