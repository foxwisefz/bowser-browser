# Panel toggles in the View menu (bowser-browser-fh5): every panel the brain
# has seen gets a checkable menu item — click to hide (suppressed: even
# event-driven mods like the dock can't re-show it) or bring it back from
# the registry's stored view. Replaced the earlier panels-panel ("a panel to
# manage panels", rightly mocked).
defmodule BowserBrain.PanelMenu do
  use BowserBrain.CoreFeature

  alias BowserBrain.{Chrome, Surface}

  def initial_state() do
    %{menu: %{}}
  end

  # Only a native reconnection rebuilds menus; backend handoff preserves them.
  def handle_event(%{"event" => "hello"}, state) do
    send(self(), :sync)
    %{state | menu: %{}}
  end

  def handle_event(%{"event" => "chrome_click", "id" => "panel:" <> sid}, state) do
    Surface.toggle(sid)
    sync(state)
  end

  def handle_event(_event, state), do: state

  def handle_info(:sync, state) do
    state = sync(state)
    {:noreply, state}
  end

  def handle_info(other, state), do: super(other, state)

  @doc """
  Menu labels, with title collisions disambiguated by the owning mod (or the
  panel id): two mods both calling their panel "Tabs" must not produce two
  identical menu entries. Public for tests.
  """

  def visible(entries), do: Enum.reject(entries, &(Map.get(&1, :kind) == "settings"))

  def menu_titles(entries) do
    counts = Enum.frequencies_by(entries, &String.downcase(&1.title))

    Map.new(entries, fn e ->
      title =
        if counts[String.downcase(e.title)] > 1 do
          "#{e.title} (#{e.owner || e.id})"
        else
          e.title
        end

      {e.id, title}
    end)
  end

  # Diff-based: only cast add/remove when an item's presence or checkmark
  # actually changed — the menu rebuild in the shell is not free.
  defp sync(state) do
    entries = visible(Surface.list())
    titles = menu_titles(entries)

    desired =
      for e <- entries, into: %{} do
        {"panel:" <> e.id, %{title: titles[e.id], checked: not e.closed}}
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
