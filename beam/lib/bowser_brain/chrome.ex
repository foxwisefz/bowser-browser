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

  @doc """
  Add/update a native bar, reserving webpage space on edge: :top/:bottom/:left/:right.
  size: 16..200 points (height for horizontal bars, width for vertical bars).
  view is a View DSL tree; style accepts background/foreground/border #rrggbb.
  Events arrive as surface events with surface: "toolbar:<id>" and webview.
  Call in init_mod and mod_reloaded. Bars die with the calling mod, replay on
  reconnect, and appear in new browser windows. Same ids shadow older owners.
  """
  def put_toolbar(id, view, opts \\ []), do: BowserBrain.Toolbars.put(to_string(id), view, opts)
  def remove_toolbar(id), do: BowserBrain.Toolbars.remove(to_string(id))
  def toolbars, do: BowserBrain.Toolbars.list()

  @doc """
  Apply a native browser skin owned by the calling mod process. Accepts a map
  with hex #rrggbb colors: background, foreground, button_background,
  button_foreground, accent, border; button_style: "flat" or "beveled";
  show_navigation: boolean; title_size: 9..16; corner_radius: 0..12.
  Full-window inner outline: window_border: #rrggbb, window_border_width:
  0..12 points, window_border_style: "flat" or "beveled". Does not alter
  macOS window shape or shadow.
  Atom or string keys are accepted. Omitted properties use native defaults.
  Call in init_mod and on mod_reloaded; reconnects replay automatically.
  Disabling/deleting the mod restores the previous theme, or native defaults.
  Returns :ok or {:error, :invalid_theme}; invalid themes leave state intact.
  """
  def set_theme(theme), do: BowserBrain.ShellTheme.set(theme)

  @doc "Remove only the calling process's theme, restoring the previous skin."
  def reset_theme, do: BowserBrain.ShellTheme.reset()

  @doc "Current effective native shell theme (string-keyed map)."
  def theme, do: BowserBrain.ShellTheme.current()

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
      key: Keyword.get(opts, :key),
      # nil = plain action item; true/false = checkable toggle.
      checked: Keyword.get(opts, :checked)
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
    msg = %{
      op: "chrome",
      chrome: "open_tab",
      url: url,
      activate: Keyword.get(opts, :activate, false)
    }

    # profile: the tab goes to (or creates) a window of that profile; tabs
    # never cross profiles.
    msg = if p = Keyword.get(opts, :profile), do: Map.put(msg, :profile, p), else: msg
    Bridge.cast_msg(msg)
  end

  @doc "A new browser window bound to a profile (see BowserBrain.Profiles)."
  def open_window(profile_id) do
    Bridge.cast_msg(%{op: "chrome", chrome: "open_window", profile: profile_id})
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
