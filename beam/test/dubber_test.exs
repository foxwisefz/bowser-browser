# Ships as an example_mods file; compile it here so its logic stays tested.
Code.put_compiler_option(:ignore_module_conflict, true)
Code.compile_file(Path.expand("../example_mods/dubber.ex", __DIR__))

defmodule DubberModTest do
  use ExUnit.Case, async: true

  test "translation parsing" do
    assert DubberMod.parse_translation(~s({"text": "Hello world"})) == {:ok, "Hello world"}
    assert DubberMod.parse_translation("not json") == {:error, :bad_response}
    assert DubberMod.parse_translation(~s({"error": "x"})) == {:error, :bad_response}
  end

  test "the mod is host-scoped to youtube.com" do
    source = File.read!(Path.expand("../example_mods/dubber.ex", __DIR__))
    assert source =~ ~s(use BowserBrain.Mod, host: "youtube.com")
  end
end

