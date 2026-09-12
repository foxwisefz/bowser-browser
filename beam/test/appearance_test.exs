defmodule BowserBrain.AppearanceTest do
  use ExUnit.Case, async: true
  alias BowserBrain.{Appearance, Toolbars, View}

  test "semantic, fixed and adaptive colors round-trip with scoped palettes" do
    palette = %{text: :ink, ink: %{light: "#112233", dark: "#ddeeff", high_contrast_dark: "#ffffff"}}
    tree = View.palette(palette, View.editor(:body, foreground: :text, background: :editor_background))
    wire = tree |> JSON.encode!() |> JSON.decode!()
    assert wire["palette"]["text"] == "ink"
    assert wire["palette"]["ink"]["dark"] == "#ddeeff"
    assert wire["content"]["foreground"] == "text"
    assert {:ok, _} = Toolbars.validate("notes", tree, edge: :right, size: 360,
      style: %{foreground: :text, background: %{light: "#ffffff", dark: "#111111"}, palette: palette, accent: :accent})
    assert Appearance.valid_color?(:secondary_text)
    assert Appearance.valid_color?("#123abc")
  end

  test "invalid variants and palettes are rejected" do
    for value <- [true, false, nil, 42, "#fff", %{light: "#ffffff"}, %{light: "#ffffff", dark: "#000000", typo: "#123456"}] do
      refute Appearance.valid_color?(value)
      assert {:error, :invalid_toolbar} = Toolbars.validate("bad", %{}, style: %{foreground: value})
    end
    refute Appearance.valid_palette?(%{"bad name" => :text})
    refute Appearance.valid_palette?(Map.new(1..65, &{"token_#{&1}", :text}))
    assert_raise ArgumentError, fn -> View.palette(%{text: true}, View.text("invalid")) end
  end
end
