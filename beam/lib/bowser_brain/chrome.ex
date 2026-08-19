defmodule BowserBrain.Chrome do
  @moduledoc """
  Browser-chrome surface points (Mod API v1). Buttons appear in every
  window's toolbar; clicks come back as events:

      Chrome.add_button("reader", "Reader", symbol: "book")
      # ... then in a mod:
      def handle_event(%{"event" => "chrome_click", "id" => "reader"}, state), do: ...

  Omnibar input starting with `:` arrives as
  `%{"event" => "omnibar_command", "text" => "..."}` — mods own that namespace.
  """

  alias BowserBrain.Bridge

  @doc "Add (or replace) a toolbar button. `symbol:` is an SF Symbol name."
  def add_button(id, title, opts \\ []) do
    Bridge.cast_msg(%{
      op: "chrome",
      chrome: "add_button",
      id: id,
      title: title,
      symbol: Keyword.get(opts, :symbol)
    })
  end

  @doc "Remove a toolbar button by id."
  def remove_button(id) do
    Bridge.cast_msg(%{op: "chrome", chrome: "remove_button", id: id})
  end

  @doc """
  Add (or replace) an item in the native View menu. `key:` is an optional
  ⌘-key equivalent (single character). Clicks arrive as `chrome_click`
  events with this id — same contract as buttons. Shell state: re-assert
  on "hello".
  """
  def add_menu_item(id, title, opts \\ []) do
    Bridge.cast_msg(%{
      op: "chrome",
      chrome: "add_menu_item",
      id: id,
      title: title,
      key: Keyword.get(opts, :key)
    })
  end

  @doc "Remove a View-menu item by id."
  def remove_menu_item(id) do
    Bridge.cast_msg(%{op: "chrome", chrome: "remove_menu_item", id: id})
  end

  @doc """
  Register an omnibar command for visual recognition: while the user types
  `:name …`, the omnibar shows `hint`. Re-register on "hello" (shell state
  dies with the engine).
  """
  def register_command(name, hint) do
    Bridge.cast_msg(%{op: "chrome", chrome: "register_command", name: name, hint: hint})
  end

  @doc """
  Open a tab. `activate: true` switches to it; by default the webview is
  created detached — it exists, loads, and shows up in tab UI, but what the
  user is looking at doesn't move. Switch later with `Surface.activate_tab/1`.
  """
  def open_tab(url \\ nil, opts \\ []) do
    Bridge.cast_msg(%{
      op: "chrome",
      chrome: "open_tab",
      url: url,
      activate: Keyword.get(opts, :activate, false)
    })
  end

  @doc """
  Deprecated no-ops (bowser-browser-cdd): there is no native tab bar any
  more. One window holds N in-memory webviews and tab UI is entirely a mod's
  job. Kept so mods written against the old API keep running.
  """
  def hide_tab_bar, do: Bridge.cast_msg(%{op: "chrome", chrome: "hide_tab_bar"})

  @doc false
  def show_tab_bar, do: Bridge.cast_msg(%{op: "chrome", chrome: "show_tab_bar"})
end
