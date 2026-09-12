Code.put_compiler_option(:ignore_module_conflict, true)
Code.compile_file(Path.expand("../example_mods/youtube_dl.ex", __DIR__))

defmodule YoutubeDlModTest do
  use ExUnit.Case, async: true

  test "netscape_cookies renders a valid cookies.txt" do
    cookies = [
      %{"name" => "SID", "value" => "abc", "domain" => ".youtube.com", "path" => "/", "secure" => true},
      %{"name" => "PREF", "value" => "xyz", "domain" => "www.youtube.com", "path" => "/", "secure" => false}
    ]

    out = YoutubeDlMod.netscape_cookies(cookies)
    assert String.starts_with?(out, "# Netscape HTTP Cookie File")
    assert out =~ ".youtube.com\tTRUE\t/\tTRUE\t2147483647\tSID\tabc"
    assert out =~ "www.youtube.com\tFALSE\t/\tFALSE\t2147483647\tPREF\txyz"
  end

  test "netscape_cookies defaults missing fields" do
    out = YoutubeDlMod.netscape_cookies([%{"name" => "X", "value" => "1"}])
    assert out =~ ".youtube.com\tTRUE\t/\tFALSE\t2147483647\tX\t1"
  end

  test "cookie file is private during download and removed after success or failure" do
    cookies = [%{"name" => "SID", "value" => "secret"}]
    path = YoutubeDlMod.with_cookie_file(cookies, fn path ->
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
      assert File.read!(path) =~ "secret"
      path
    end)
    refute File.exists?(Path.dirname(path))

    parent = self()
    assert_raise RuntimeError, "download failed", fn ->
      YoutubeDlMod.with_cookie_file(cookies, fn path ->
        send(parent, {:cookie_path, path})
        raise "download failed"
      end)
    end
    assert_receive {:cookie_path, failed_path}
    refute File.exists?(Path.dirname(failed_path))
    refute path == failed_path
  end

  test "final_path pulls the saved file from yt-dlp output" do
    merge = ~s([download] Destination: /x/a.f137.mp4\n[Merger] Merging formats into "/Users/g/Downloads/Cool [abc].mp4")
    assert YoutubeDlMod.final_path(merge) == "/Users/g/Downloads/Cool [abc].mp4"

    single = "[download] Destination: /Users/g/Downloads/Solo [id].mp4\n[download] 100%"
    assert YoutubeDlMod.final_path(single) == "/Users/g/Downloads/Solo [id].mp4"

    cached = "[download] /Users/g/Downloads/Seen [id].mp4 has already been downloaded"
    assert YoutubeDlMod.final_path(cached) == "/Users/g/Downloads/Seen [id].mp4"

    assert YoutubeDlMod.final_path("nothing useful") == nil
  end
end
