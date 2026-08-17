# Proving mod for ADR 0009 surfaces: a floating native palette (real SwiftUI,
# described from Elixir) with page tools that work on any site.
defmodule PageToolsMod do
  use BowserBrain.Mod
  import BowserBrain.View
  alias BowserBrain.{Page, Surface}

  def init_mod(_opts) do
    render(%{active: 0, dark: false, clutter: false, zoom: 1.0})
  end

  def handle_event(%{"event" => "hello"}, state), do: render(state)

  def handle_event(%{"event" => "tab_activated", "webview" => wv}, state) do
    %{state | active: wv}
  end

  def handle_event(%{"event" => "surface", "surface" => "page_tools", "id" => id} = event, state) do
    case id do
      "dark" ->
        Page.eval(dark_js(), webview: state.active)
        render(%{state | dark: !state.dark})

      "declutter" ->
        Page.eval(declutter_js(), webview: state.active)
        render(%{state | clutter: !state.clutter})

      "zoom" ->
        zoom = event["value"] || 1.0
        Page.eval("document.body.style.zoom = #{zoom}; true", webview: state.active)
        %{state | zoom: zoom}

      _ ->
        state
    end
  end

  def handle_event(_event, state), do: state

  defp render(state) do
    Surface.show(
      :page_tools,
      vstack([
        text("Page tools", style: :title),
        button("Dark mode", event: :dark, active: state.dark, symbol: "moon.fill"),
        button("Declutter", event: :declutter, active: state.clutter, symbol: "scissors"),
        divider(),
        slider(:zoom, min: 0.5, max: 2.0, value: state.zoom, label: "Zoom")
      ]),
      title: "Page",
      anchor: :right_of_main
    )

    state
  end

  defp dark_js do
    """
    (function () {
      var s = document.getElementById("bowser-dark");
      if (s) { s.remove(); return false; }
      s = document.createElement("style");
      s.id = "bowser-dark";
      s.textContent =
        "html { filter: invert(1) hue-rotate(180deg) !important; background: #111 !important; }" +
        "img, video, iframe, svg, canvas { filter: invert(1) hue-rotate(180deg) !important; }";
      document.head.appendChild(s);
      return true;
    })()
    """
  end

  defp declutter_js do
    """
    (function () {
      var s = document.getElementById("bowser-declutter");
      if (s) { s.remove(); return false; }
      s = document.createElement("style");
      s.id = "bowser-declutter";
      s.textContent = "aside, nav, footer, iframe, [class*='banner'], [class*='promo'] { display: none !important; }";
      document.head.appendChild(s);
      return true;
    })()
    """
  end
end
