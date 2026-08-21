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

defmodule DubberHlsTest do
  use ExUnit.Case, async: true

  @master """
  #EXTM3U
  #EXT-X-STREAM-INF:BANDWIDTH=2969000,RESOLUTION=1280x720
  https://example.com/hi/index.m3u8
  #EXT-X-STREAM-INF:BANDWIDTH=290000,RESOLUTION=256x144
  low/index.m3u8
  """

  @media """
  #EXTM3U
  #EXTINF:5.5,
  seg0.ts
  #EXTINF:5.5,
  seg1.ts
  #EXTINF:5.5,
  https://cdn.example.com/seg2.ts
  """

  test "lowest-bandwidth variant wins, relative URIs absolutized" do
    assert DubberMod.hls_lowest_variant(@master, "https://example.com/master.m3u8") ==
             "https://example.com/low/index.m3u8"
  end

  test "media segments absolutized and capped by duration" do
    segs = DubberMod.hls_segments(@media, "https://example.com/low/index.m3u8", 900)
    assert segs == [
             "https://example.com/low/seg0.ts",
             "https://example.com/low/seg1.ts",
             "https://cdn.example.com/seg2.ts"
           ]

    assert DubberMod.hls_segments(@media, "https://example.com/low/index.m3u8", 10) |> length() == 2
  end
end
