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

  test "compile_all retries a file that needed another changed file first" do
    dir = Path.join(System.tmp_dir!(), "reload-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    a = Path.join(dir, "a.ex")
    b = Path.join(dir, "b.ex")
    File.write!(a, "defmodule ReloadOrderA do\n  def a, do: :a\nend\n")
    File.write!(b, "defmodule ReloadOrderB do\n  import ReloadOrderA\n  def b, do: a()\nend\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    Code.put_compiler_option(:ignore_module_conflict, true)

    # b first: its import fails until a exists — the retry pass fixes it.
    {compiled, failed} = LibReloader.compile_all([b, a])
    assert failed == []
    assert Enum.sort(compiled) == Enum.sort([a, b])
    assert ReloadOrderB.b() == :a
  end

  test "compile_all reports a file that can never compile" do
    dir = Path.join(System.tmp_dir!(), "reload-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    bad = Path.join(dir, "bad.ex")
    File.write!(bad, "defmodule Nope do\n  def x, do: undefined_thing()\nend\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    {[], [^bad]} = LibReloader.compile_all([bad])
  end
end
