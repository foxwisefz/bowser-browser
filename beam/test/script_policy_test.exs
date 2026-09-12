defmodule BowserBrain.ScriptPolicyTest do
  use ExUnit.Case, async: true
  alias BowserBrain.ScriptPolicy

  defmodule SiteOwner do
    def __bowser_host__, do: "example.com"
  end

  test "default world is isolated and invalid worlds fail closed" do
    assert ScriptPolicy.normalize("window.privateValue = 1") == %{source: "window.privateValue = 1", world: "isolated"}
    assert ScriptPolicy.normalize("x", world: :page).world == "page"
    assert ScriptPolicy.normalize(%{"source" => "x", "world" => "page"}).world == "page"
    assert_raise ArgumentError, fn -> ScriptPolicy.normalize("x", world: :unknown) end
    assert_raise ArgumentError, fn -> ScriptPolicy.normalize(%{source: "x", world: nil}) end
  end

  test "page capability marker is only recognized at the initial declaration" do
    assert ScriptPolicy.source_world("// bowser-world: page\nwindow.x") == "page"
    assert ScriptPolicy.source_world("\n// bowser-profile: work\n\n// bowser-world: page\nx") == "page"
    assert ScriptPolicy.source_world("var x = 1;\n// bowser-world: page") == "isolated"
    assert ScriptPolicy.source_world("// unrelated\n// bowser-world: page") == "isolated"
    assert_raise ArgumentError, fn -> ScriptPolicy.source_world("// bowser-world: unsafe\nx") end
  end

  test "declared host cannot be widened by a descriptor" do
    host = ScriptPolicy.owner_host(SiteOwner)
    assert ScriptPolicy.normalize(%{source: "x", host: "other.test"}, host: host).host == "example.com"
  end
end
