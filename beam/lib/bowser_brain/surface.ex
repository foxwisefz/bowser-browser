defmodule BowserBrain.Surface do
  @moduledoc """
  Mod-owned native surfaces (ADR 0009). Show/update a floating panel with a
  view tree from BowserBrain.View; calling show/3 again with the same id
  re-renders in place — so mods just re-show on every state change.

      Surface.show(:my_panel, view, title: "Page", anchor: :right_of_main)
      Surface.close(:my_panel)

  Surfaces die with the engine; re-show on the "hello" event (or just on the
  next event you care about) to resurrect them.

  Also the panel REGISTRY (bowser-browser-27l): every show is recorded —
  id, title, kind, owning mod, last view tree — so panels are enumerable
  (`list/0`) and resurrectable (`reshow/1`). The :panels directory mod is
  built on this; without it the owner has no way to know which panel views
  even exist.
  """
  use GenServer

  alias BowserBrain.Bridge

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def show(id, view, opts \\ []) when is_map(view) do
    # The registry decides whether the engine sees this show: a SUPPRESSED
    # panel (toggled off in the View menu) records the fresh view but drops
    # the cast — otherwise event-driven mods like the dock re-show
    # themselves seconds after every toggle-off. Registry down (old brain):
    # degrade to always-show.
    suppressed? =
      try do
        GenServer.call(__MODULE__, {:shown, to_string(id), view, opts, self()}, 1_000)
      catch
        :exit, _ -> false
      end

    unless suppressed?, do: Bridge.cast_msg(show_msg(id, view, opts))
    :ok
  end

  def close(id) do
    GenServer.cast(__MODULE__, {:closed, to_string(id)})
    Bridge.cast_msg(%{op: "surface", surface: "close", id: to_string(id)})
  end

  @doc "Every panel ever shown this brain-lifetime: id, title, kind, owner, closed."
  def list do
    GenServer.call(__MODULE__, :list)
  catch
    :exit, _ -> []
  end

  @doc "Re-show a known panel from its stored view tree."
  def reshow(id) do
    GenServer.call(__MODULE__, {:reshow, to_string(id)})
  catch
    :exit, _ -> {:error, :registry_down}
  end

  @doc """
  View-menu toggle: a visible panel is suppressed and closed (shows keep
  recording but stop reaching the engine); a hidden one is unsuppressed and
  re-shown from its stored view. Returns {:ok, :hidden | :shown}.
  """
  def toggle(id) do
    GenServer.call(__MODULE__, {:toggle, to_string(id)})
  catch
    :exit, _ -> {:error, :registry_down}
  end

  @doc "Bring a tab's window to front."
  def activate_tab(webview), do: Bridge.cast_msg(%{op: "activate_tab", webview: webview})

  @doc "Close a tab's window."
  def close_tab(webview), do: Bridge.cast_msg(%{op: "close_tab", webview: webview})

  # ---------------------------------------------------------------------

  @impl true
  def init(nil) do
    {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
    {:ok, %{panels: %{}, suppressed: MapSet.new()}}
  end

  # Engine hello = fresh engine = every panel is gone until re-shown. The
  # dispatch reaches us before any mod's re-show cast can, so ordering holds.
  @impl true
  def handle_info({:browser_event, %{"event" => "hello"}}, state) do
    panels = Map.new(state.panels, fn {id, e} -> {id, %{e | closed: true}} end)
    {:noreply, %{state | panels: panels}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast({:closed, id}, state) do
    {:noreply, update_entry(state, id, &%{&1 | closed: true})}
  end

  @impl true
  def handle_call({:shown, id, view, opts, owner_pid}, _from, state) do
    suppressed? = MapSet.member?(state.suppressed, id)

    entry = %{
      id: id,
      title: Keyword.get(opts, :title, id),
      kind: to_string(Keyword.get(opts, :kind, :floating)),
      owner: owner_name(owner_pid),
      view: view,
      opts: opts,
      shown_at: System.system_time(:millisecond),
      closed: suppressed?
    }

    {:reply, suppressed?, put_in(state.panels[id], entry)}
  end

  def handle_call(:list, _from, state) do
    entries =
      state.panels
      |> Map.values()
      |> Enum.sort_by(& &1.shown_at, :desc)
      |> Enum.map(fn e ->
        e
        |> Map.take([:id, :title, :kind, :owner, :closed, :shown_at])
        |> Map.put(:suppressed, MapSet.member?(state.suppressed, e.id))
      end)

    {:reply, entries, state}
  end

  def handle_call({:reshow, id}, _from, state) do
    case state.panels do
      %{^id => entry} ->
        Bridge.cast_msg(show_msg(id, entry.view, entry.opts))
        state = %{state | suppressed: MapSet.delete(state.suppressed, id)}
        {:reply, :ok, update_entry(state, id, &%{&1 | closed: false})}

      _ ->
        {:reply, {:error, :unknown}, state}
    end
  end

  def handle_call({:toggle, id}, _from, state) do
    case state.panels do
      %{^id => entry} ->
        if entry.closed or MapSet.member?(state.suppressed, id) do
          Bridge.cast_msg(show_msg(id, entry.view, entry.opts))
          state = %{state | suppressed: MapSet.delete(state.suppressed, id)}
          {:reply, {:ok, :shown}, update_entry(state, id, &%{&1 | closed: false})}
        else
          Bridge.cast_msg(%{op: "surface", surface: "close", id: id})
          state = %{state | suppressed: MapSet.put(state.suppressed, id)}
          {:reply, {:ok, :hidden}, update_entry(state, id, &%{&1 | closed: true})}
        end

      _ ->
        {:reply, {:error, :unknown}, state}
    end
  end

  defp update_entry(state, id, fun) do
    case state.panels do
      %{^id => entry} -> put_in(state.panels[id], fun.(entry))
      _ -> state
    end
  end

  defp show_msg(id, view, opts) do
    %{
      op: "surface",
      surface: "show",
      id: to_string(id),
      # :floating (default), :toolbar_overlay (click-through effects layer
      # over the toolbar), or :edge (window-edge surface, mostly hidden with
      # a peek sliver, slides into view on cursor proximity — edge:/peek:).
      kind: to_string(Keyword.get(opts, :kind, :floating)),
      edge: to_string(Keyword.get(opts, :edge, :left)),
      peek: Keyword.get(opts, :peek, 6),
      # :window (follows the browser window) or :screen (macOS-Dock style).
      attach: to_string(Keyword.get(opts, :attach, :window)),
      title: Keyword.get(opts, :title, to_string(id)),
      anchor: to_string(Keyword.get(opts, :anchor, :right_of_main)),
      width: Keyword.get(opts, :width, 260),
      view: view
    }
  end

  # Which mod (or named process) showed this panel — for the directory.
  defp owner_name(pid) do
    case Registry.keys(BowserBrain.ModRegistry, pid) do
      [module | _] ->
        inspect(module)

      [] ->
        case Process.info(pid, :registered_name) do
          {:registered_name, name} when is_atom(name) and name != nil -> inspect(name)
          _ -> nil
        end
    end
  end
end
