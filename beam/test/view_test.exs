defmodule BowserBrain.ViewTest do
  use ExUnit.Case, async: true

  alias BowserBrain.View

  test "strip chrome is a composable JSON tree, including profile bindings and actions" do
    header = BowserBrain.TabDeck.profile_header("work")
    footer = View.action("New tab", event: "new", symbol: "plus")
    tree = View.magnify_strip([], header: header, footer: footer, header_height: 48, header_outside: true,
      footer_height: 32, chrome: "notch", background: "#112233")
    decoded = tree |> JSON.encode!() |> JSON.decode!()
    assert Map.take(decoded["header"], ["t", "profile_id", "size"]) == %{"t" => "profile_avatar", "profile_id" => "work", "size" => 18}
    assert decoded["header"]["badge"] == true
    assert decoded["footer"]["event"] == "new"
    assert decoded["header_height"] == 48
    assert decoded["header_outside"] == true
    assert decoded["background"] == "#112233"
  end

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

  test "native form and presentation trees round-trip over the wire" do
    response = View.form_response("request-1", {:error, %{"name" => "Already taken"}})
    tree = View.form(:editor, %{"name" => "Work"},
      View.fields([
        View.field("Name:", View.input(:name), key: :name),
        View.field("Avatar:", View.popover(:avatar, "Choose", View.input(:avatar, kind: :choice,
          options: [%{value: "star", label: "Star", symbol: "star"}]), width: 360), key: :avatar)
      ]), required: [:name], response: response)
    wire = tree |> JSON.encode!() |> JSON.decode!()
    assert wire["key"] == "editor"
    assert wire["required"] == ["name"]
    assert wire["response"]["errors"]["name"] == "Already taken"
    assert get_in(wire, ["content", "children", Access.at(1), "content", "content_width"]) == 360
    refute Map.has_key?(Enum.at(tree.content.children, 1).content, :width)
  end

  test "layout and action semantics compose without changing legacy buttons" do
    assert %{t: "vstack", alignment: :trailing, key: "group", padding: 20} =
      View.vstack([], alignment: :trailing, key: :group, padding: 20)
    assert %{t: "action", role: :destructive, disabled: true, shortcut: :cancel} =
      View.action("Remove", role: :destructive, disabled: true, shortcut: :cancel)
    assert %{t: "button"} = View.button("Old button", event: :click)
    assert %{t: "grid", columns: 3} = View.grid([], columns: 3)
    assert %{t: "list_detail", sidebar_width: 200} = View.list_detail([], sidebar_width: 200)
    assert %{ok: true, values: %{"name" => "Saved"}} = View.form_response("id", {:ok, %{"name" => "Saved"}})
  end

end
