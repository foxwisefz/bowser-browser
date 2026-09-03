defmodule BowserBrain.PathsTest do
  use ExUnit.Case, async: true

  alias BowserBrain.Paths

  test "BOWSER_ENGINE names the browser binary; otherwise the checkout's debug build" do
    assert Paths.engine_binary(%{"BOWSER_ENGINE" => "/Users/x/.bowser/app/Bowser.app/Contents/MacOS/Bowser"}) ==
             "/Users/x/.bowser/app/Bowser.app/Contents/MacOS/Bowser"

    assert String.ends_with?(Paths.engine_binary(%{}), "shell/.build/debug/Bowser")
    assert String.ends_with?(Paths.engine_binary(%{"BOWSER_ENGINE" => ""}), "shell/.build/debug/Bowser")
  end
end
