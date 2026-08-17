# Reader mode as a mod: a toolbar button that toggles engine-injected CSS.
# Drop into ~/.bowser/mods/ — the button appears in the toolbar of every
# window within a second. Also try `:reader` in the omnibar.
defmodule ReaderMod do
  use BowserBrain.Mod

  alias BowserBrain.{Chrome, Page}

  @css """
  * { animation: none !important; transition: none !important; }
  body { max-width: 68ch !important; margin: 0 auto !important;
         font-family: Georgia, serif !important; font-size: 19px !important;
         line-height: 1.6 !important; background: #faf8f2 !important;
         color: #222 !important; padding: 2rem 1rem !important; }
  aside, nav, footer, iframe, [class*="banner"], [class*="promo"],
  [id*="sidebar"], video { display: none !important; }
  img { max-width: 100% !important; height: auto !important; }
  """

  def init_mod(_opts) do
    Chrome.add_button("reader", "Reader", symbol: "book")
    %{on: false}
  end

  def handle_event(%{"event" => "chrome_click", "id" => "reader"}, state), do: toggle(state)
  def handle_event(%{"event" => "omnibar_command", "text" => "reader"}, state), do: toggle(state)

  # Engine restarted: chrome state is gone, ours isn't — re-assert it.
  def handle_event(%{"event" => "hello"}, state) do
    Chrome.add_button("reader", "Reader", symbol: "book")
    if state.on, do: Page.set_styles([@css])
    state
  end

  def handle_event(_event, state), do: state

  defp toggle(%{on: false} = state) do
    Page.set_styles([@css])
    %{state | on: true}
  end

  defp toggle(%{on: true} = state) do
    Page.set_styles([])
    %{state | on: false}
  end
end
