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
  Register an omnibar command for visual recognition: while the user types
  `:name …`, the omnibar shows `hint`. Re-register on "hello" (shell state
  dies with the engine).
  """
  def register_command(name, hint) do
    Bridge.cast_msg(%{op: "chrome", chrome: "register_command", name: name, hint: hint})
  end
end
