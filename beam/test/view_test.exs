defmodule BowserBrain.ViewTest do
  use ExUnit.Case, async: true

  alias BowserBrain.View

  test "colorpicker node carries event, current hex and label" do
    assert View.colorpicker("pick|work", value: "#3e63dd", label: "Tint") ==
             %{t: "colorpicker", event: "pick|work", value: "#3e63dd", label: "Tint"}

    assert View.colorpicker(:c) == %{t: "colorpicker", event: "c", value: nil, label: ""}
  end

  test "textfield carries an initial value" do
    assert %{t: "textfield", event: "name|work", value: "Work"} = View.textfield("name|work", value: "Work")
  end
end
