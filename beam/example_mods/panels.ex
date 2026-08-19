# Panel toggles in the View menu (bowser-browser-fh5): every panel the brain
# has seen gets a checkable menu item — click to hide (suppressed: even
# event-driven mods like the dock can't re-show it) or bring it back from
# the registry's stored view. Replaced the earlier panels-panel ("a panel to
# manage panels", rightly mocked).
defmodule PanelsMod do
  use BowserBrain.Mod

  alias BowserBrain.{Chrome, Surface}

  @sync_ms 2_000

  def init_mod(_opts) do
    Process.send_after(self(), :sync, @sync_ms)
    %{menu: %{}}
  end

  # Menu items are shell state and die with the engine; the sync tick
  # rebuilds them, so hello just resets our bookkeeping.
  def handle_event(%{"event" => "hello"}, state), do: %{state | menu: %{}}

  def handle_event(%{"event" => "chrome_click", "id" => "panel:" <> sid}, state) do
    Surface.toggle(sid)
    sync(state)
  end

  def handle_event(_event, state), do: state

  def handle_info(:sync, state) do
    state = sync(state)
    Process.send_after(self(), :sync, @sync_ms)
    {:noreply, state}
  end

  def handle_info(other, state), do: super(other, state)

  # Diff-based: only cast add/remove when an item's presence or checkmark
  # actually changed — the menu rebuild in the shell is not free.
  defp sync(state) do
    desired =
      for e <- Surface.list(), into: %{} do
        {"panel:" <> e.id, %{title: e.title, checked: not e.closed}}
      end

    for {id, item} <- desired, state.menu[id] != item do
      Chrome.add_menu_item(id, item.title, checked: item.checked)
    end

    for {id, _} <- state.menu, not Map.has_key?(desired, id) do
      Chrome.remove_menu_item(id)
    end

    %{state | menu: desired}
  end
end
