defmodule BowserBrain.PathsTest do
  use ExUnit.Case, async: false

  alias BowserBrain.Paths

  test "root defaults to the checkout this brain was compiled from" do
    # beam/test/ -> repo root is two levels up.
    assert Paths.root() == Path.expand("../..", __DIR__)
    assert File.dir?(Path.join(Paths.root(), "beam"))
  end

  test "root honours the :root app env override" do
    Application.put_env(:bowser_brain, :root, "/somewhere/else")
    on_exit(fn -> Application.delete_env(:bowser_brain, :root) end)

    assert Paths.root() == "/somewhere/else"
    assert Paths.engine_binary() == "/somewhere/else/shell/.build/debug/Bowser"
    assert Paths.engine_wrapper() == "/somewhere/else/bin/engine-wrapper"
    assert Paths.brain_lib() == "/somewhere/else/beam/lib/bowser_brain"
    assert Paths.mcp_bridge() == "/somewhere/else/bin/bowser-mcp-bridge"
  end

  test "derived paths sit under the default root" do
    for path <- [
          Paths.engine_binary(),
          Paths.engine_wrapper(),
          Paths.brain_lib(),
          Paths.mcp_bridge()
        ] do
      assert String.starts_with?(path, Paths.root())
    end
  end
end
