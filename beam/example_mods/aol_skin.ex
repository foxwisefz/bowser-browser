defmodule AOLSkinMod do
  @moduledoc "Classic AOL-inspired blue shell and silver beveled navigation."
  use BowserBrain.Mod
  alias BowserBrain.Chrome

  def init_mod(_) do
    apply_theme()
    %{}
  end

  def handle_event(%{"event" => "mod_reloaded"}, state) do
    apply_theme()
    state
  end

  def handle_event(_, state), do: state

  defp apply_theme do
    Chrome.set_theme(%{
      background: "#0047AB",
      foreground: "#FFFFFF",
      button_background: "#C0C0C0",
      button_foreground: "#101010",
      accent: "#FFD700",
      border: "#666666",
      button_style: "beveled",
      show_navigation: true,
      title_size: 13,
      corner_radius: 2
    })
  end
end
