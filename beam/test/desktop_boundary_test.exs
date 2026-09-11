defmodule BowserBrain.DesktopBoundaryTest do
  use ExUnit.Case, async: true

  test "desktop application contains no mobile experiment services or modules" do
    for name <- ["XFeed", "XServer", "XAdapter", "SDUI"] do
      module = Module.concat(BowserBrain, name)
      refute module in Application.spec(:bowser_brain, :modules)
      refute Code.ensure_loaded?(module)
      assert Process.whereis(module) == nil
    end
  end
end
