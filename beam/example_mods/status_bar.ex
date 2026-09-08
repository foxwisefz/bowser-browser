defmodule StatusBarMod do
  @moduledoc "A native bottom status bar and beveled window outline."
  use BowserBrain.Mod
  import BowserBrain.View
  alias BowserBrain.Chrome

  def init_mod(_) do
    install()
    %{}
  end

  def handle_event(%{"event" => "mod_reloaded"}, state) do
    install()
    state
  end

  def handle_event(%{"event" => "surface", "surface" => "toolbar:status",
                     "id" => "home", "webview" => webview}, state) do
    BowserBrain.Browser.navigate("https://www.aol.com/", webview)
    state
  end

  def handle_event(_, state), do: state

  defp install do
    Chrome.set_theme(%{window_border: "#808080", window_border_width: 4,
                       window_border_style: "beveled"})
    Chrome.put_toolbar("status", hstack([
      text("Ready", style: :caption), button("AOL Home", event: "home", symbol: "house")
    ], spacing: 12), edge: :bottom, size: 32,
      style: %{background: "#C0C0C0", foreground: "#101010", border: "#808080"})
  end
end
