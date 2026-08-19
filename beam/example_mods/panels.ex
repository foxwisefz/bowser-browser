# The panel directory (bowser-browser-27l): `:panels` in the omnibar (or
# View menu → Panels) lists every panel the brain has seen this lifetime —
# tabs dock, twitter nav, ModSmith, whatever mods conjured — and one click
# brings any of them back. Solves "I can't see or know which panel views
# are available to me": surfaces die with engine rolls or only appear on
# events, and before this there was no way to enumerate or resurrect them.
defmodule PanelsMod do
  use BowserBrain.Mod

  import BowserBrain.View

  alias BowserBrain.{Chrome, Surface}

  def init_mod(_opts) do
    assert_chrome()
    %{}
  end

  # IRON RULE: shell-side chrome dies with the engine — re-assert on hello.
  def handle_event(%{"event" => "hello"}, state) do
    assert_chrome()
    state
  end

  def handle_event(%{"event" => "omnibar_command", "text" => "panels"}, state) do
    render()
    state
  end

  def handle_event(%{"event" => "chrome_click", "id" => "panels"}, state) do
    render()
    state
  end

  # Directory click: re-show that panel from the registry.
  def handle_event(
        %{"event" => "surface", "surface" => "panels", "id" => "open", "value" => id},
        state
      ) do
    Surface.reshow(id)
    render()
    state
  end

  def handle_event(_event, state), do: state

  defp assert_chrome do
    Chrome.register_command("panels", "List every available panel")
    Chrome.add_menu_item("panels", "Panels")
  end

  defp render do
    entries = Surface.list() |> Enum.reject(&(&1.id == "panels"))

    rows =
      case entries do
        [] ->
          [text("No panels seen yet — they appear here as mods show them.", style: :caption)]

        entries ->
          Enum.map(entries, fn e ->
            label = "#{e.title}#{if e.closed, do: " (closed)"}"
            hint = [e.owner, e.kind] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

            vstack([
              button(label, event: "open", payload: e.id),
              text(hint, style: :caption)
            ])
          end)
      end

    Surface.show(
      :panels,
      vstack([text("Panels", style: :title)] ++ rows ++ [divider(), text(":panels reopens this", style: :caption)]),
      title: "Panels",
      anchor: :right_of_main,
      width: 260
    )
  end
end
