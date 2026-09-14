defmodule BowserBrain.PathsTest do
  use ExUnit.Case, async: true

  alias BowserBrain.Paths

  test "BOWSER_ENGINE names the browser binary; otherwise the checkout's debug build" do
    assert Paths.engine_binary(%{"BOWSER_ENGINE" => "/Users/x/Applications/Bowser.app/Contents/MacOS/Bowser"}) ==
             "/Users/x/Applications/Bowser.app/Contents/MacOS/Bowser"

    assert String.ends_with?(Paths.engine_binary(%{}), "shell/.build/debug/Bowser")
    assert String.ends_with?(Paths.engine_binary(%{"BOWSER_ENGINE" => ""}), "shell/.build/debug/Bowser")
  end

  test "BOWSER_HOME relocates the whole state dir; default is ~/.bowser" do
    assert Paths.home(%{"BOWSER_HOME" => "~/.bowser-dev"}) == Path.expand("~/.bowser-dev")
    assert Paths.home(%{}) == Path.join(System.user_home!(), ".bowser")
    assert Paths.home(%{"BOWSER_HOME" => ""}) == Path.join(System.user_home!(), ".bowser")
  end
  test "Claude discovery finds a native installation outside the GUI PATH" do
    root = Path.join(System.tmp_dir!(), "bowser-claude-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    native = Path.join(root, ".local/bin/claude")
    File.mkdir_p!(Path.dirname(native))
    File.write!(native, "#!/bin/sh\nexit 0\n")
    File.chmod!(native, 0o700)
    assert Paths.claude_executable(root, "/usr/bin:/bin:/usr/sbin:/sbin", []) == native

    custom = Path.join(root, "custom/claude")
    File.mkdir_p!(Path.dirname(custom))
    File.write!(custom, "#!/bin/sh\nexit 0\n")
    File.chmod!(custom, 0o700)
    assert Paths.claude_executable(root, Path.dirname(custom), []) == custom
  end

  test "Claude discovery skips nonexecutable files and broken links, then checks package installs" do
    root = Path.join(System.tmp_dir!(), "bowser-claude-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    native = Path.join(root, ".local/bin/claude")
    File.mkdir_p!(Path.dirname(native))
    File.write!(native, "not executable")
    File.chmod!(native, 0o600)
    assert Paths.claude_executable(root, "", []) == nil
    File.rm!(native)
    File.ln_s!(Path.join(root, "missing"), native)
    assert Paths.claude_executable(root, "", []) == nil

    package = Path.join(root, "package/claude")
    File.mkdir_p!(Path.dirname(package))
    File.write!(package, "#!/bin/sh\nexit 0\n")
    File.chmod!(package, 0o700)
    assert Paths.claude_executable(root, "", [Path.dirname(package)]) == package
  end

end
