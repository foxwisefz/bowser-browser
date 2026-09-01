defmodule BowserBrain.LibReloaderTest do
  use ExUnit.Case, async: true

  alias BowserBrain.LibReloader

  test "changed/2 includes modified AND brand-new files, excludes unchanged" do
    previous = %{"a.ex" => 1, "b.ex" => 5}
    current = %{"a.ex" => 1, "b.ex" => 6, "new.ex" => 9}
    assert Enum.sort(LibReloader.changed(previous, current)) == ["b.ex", "new.ex"]
  end

  test "changed/2 is empty when nothing moved" do
    assert LibReloader.changed(%{"a.ex" => 1}, %{"a.ex" => 1}) == []
  end
end
