defmodule BowserBrain.PrivateFilesTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias BowserBrain.PrivateFiles

  setup do
    root = Path.join(System.tmp_dir!(), "bowser-private-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false))
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "socket parent is private and symlink parents are rejected", %{root: root} do
    dir = Path.join(root, "ipc")
    PrivateFiles.directory!(dir)
    assert band(File.stat!(dir).mode, 0o777) == 0o700
    link = Path.join(root, "link")
    File.ln_s!(dir, link)
    assert_raise ArgumentError, fn -> PrivateFiles.directory!(link) end
  end

  test "secret writes are private and replace symlinks without altering their target", %{root: root} do
    path = Path.join(root, "settings.json")
    outside = Path.join(root, "other")
    File.write!(outside, "untouched")
    File.ln_s!(outside, path)
    assert {:error, :invalid_file_type} = PrivateFiles.read(path)
    PrivateFiles.write!(path, "secret")
    assert File.read!(outside) == "untouched"
    assert File.read!(path) == "secret"
    assert band(File.stat!(path).mode, 0o777) == 0o600
    File.chmod!(path, 0o644)
    assert {:ok, "secret"} = PrivateFiles.read(path)
    assert band(File.stat!(path).mode, 0o777) == 0o600
    assert Enum.sort(File.ls!(root)) == ["other", "settings.json"]
  end
end
