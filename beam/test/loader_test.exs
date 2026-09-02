defmodule BowserBrain.LoaderTest do
  use ExUnit.Case, async: true

  alias BowserBrain.Loader

  test "vanished/2 lists paths the previous scan had that the current one lacks" do
    assert Loader.vanished(%{"a.ex" => 1, "b.ex" => 2}, %{"a.ex" => 1}) == ["b.ex"]
    assert Loader.vanished(%{"a.ex" => 1}, %{"a.ex" => 9, "new.ex" => 1}) == []
  end

  test "modules_in/1 reads declared modules from source; missing file is empty" do
    path = Path.join(System.tmp_dir!(), "loader-#{System.unique_integer([:positive])}.ex")
    File.write!(path, "# a mod\ndefmodule Some.ModA do\nend\ndefmodule ModB do\nend\n")
    on_exit(fn -> File.rm(path) end)
    assert Loader.modules_in(path) == [Some.ModA, ModB]
    assert Loader.modules_in(path <> ".nope") == []
  end
end
