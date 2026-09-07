# Optional demo: copy into the mods directory, then use :native-settings.
# State is intentionally in memory; replace validate/save with your persistence.
defmodule NativeSettingsMod do
  use BowserBrain.Mod
  import BowserBrain.View
  alias BowserBrain.{Chrome, Surface}

  def init_mod(_opts) do
    Chrome.register_command("native-settings", "Native form and layout example")
    %{values: %{"name" => "Reading", "enabled" => true, "color" => "#3e63dd", "icon" => "book"}, response: nil}
  end

  def handle_event(%{"event" => "hello"}, state) do
    Chrome.register_command("native-settings", "Native form and layout example")
    state
  end

  def handle_event(%{"event" => "omnibar_command", "text" => "native-settings"}, state), do: render(state, true)

  def handle_event(%{"event" => "surface", "surface" => "native-settings", "id" => "save",
                    "value" => %{"request_id" => id, "values" => values}}, state) do
    # Always validate in the brain; client validation is only convenience.
    name = values["name"]
    if is_binary(name) and String.trim(name) != "" and String.length(name) <= 40 do
      values = Map.put(values, "name", String.trim(name))
      render(%{state | values: values, response: form_response(id, {:ok, values})})
    else
      render(%{state | response: form_response(id, {:error, %{"name" => "Use a name between 1 and 40 characters."}})})
    end
  end

  def handle_event(_event, state), do: state

  def view(state) do
    editor = form("reading-editor", state.values,
      fields([
        field("Name:", input(:name, label: "Collection name"), key: :name),
        field("Enabled:", input(:enabled, kind: :toggle, label: "Show in sidebar"), key: :enabled),
        field("Color:", input(:color, kind: :color, label: "Window color"), key: :color),
        field("Icon:", popover(:icons, "Choose an icon…",
          input(:icon, kind: :choice, columns: 3, options: [
            %{value: "book", label: "Reading", symbol: "book"},
            %{value: "star", label: "Favorites", symbol: "star"},
            %{value: "globe", label: "Research", symbol: "globe"}
          ]), width: 300), key: :icon)
      ]), event: :save, required: [:name], labels: %{name: "a collection name"}, response: state.response)

    vstack([
      text("Native mod settings", style: :heading),
      text("Forms keep your edits while the mod refreshes.", style: :caption),
      list_detail([
        %{id: "reading", title: "Reading", symbol: "book", detail: editor},
        %{id: "about", title: "About", symbol: "info.circle", detail:
          vstack([
            text("Reusable native controls", style: :heading),
            grid([group("Layout", text("Aligned fields and stable selection")),
                  group("Forms", text("Local drafts and acknowledged saves"))], columns: 2),
            sheet(:help, "Open help sheet", vstack([
              text("A native sheet", style: :heading),
              text("Any view tree can be presented here."),
              action("Done", action: :dismiss, role: :primary, shortcut: :cancel)
            ]), width: 420)
          ], spacing: 20)}
      ], key: :sections, min_height: 360)
    ], spacing: 16, fill_width: true)
  end

  defp render(state, activate \\ false) do
    Surface.show("native-settings", view(state), title: "Native UI", kind: :settings, order: 30, activate: activate)
    state
  end
end
