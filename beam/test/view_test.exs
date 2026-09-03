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

  test "row, toggle and section nodes" do
    assert %{t: "row", title: "Dock", subtitle: "tabs", swatch: "#3e63dd", trailing: [%{t: "toggle"}], event: "pick", payload: 1} =
             View.row("Dock", subtitle: "tabs", swatch: "#3e63dd", trailing: [View.toggle("t")], event: "pick", payload: 1)

    assert View.toggle("toggle", on: true, payload: "mod|x.ex") ==
             %{t: "toggle", event: "toggle", on: true, payload: "mod|x.ex", label: ""}

    assert View.section("Global mods") == %{t: "section", value: "Global mods"}
  end
end
