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
end
