defmodule BowserBrain.Surface do
  @moduledoc """
  Mod-owned native surfaces (ADR 0009). Show/update a floating panel with a
  view tree from BowserBrain.View; calling show/3 again with the same id
  re-renders in place — so mods just re-show on every state change.

      Surface.show(:page_tools, view, title: "Page", anchor: :right_of_main)
      Surface.close(:page_tools)

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
    # Record first (registry may be down on an old brain: cast is a no-op),
    # then drive the engine.
    GenServer.cast(__MODULE__, {:shown, to_string(id), view, opts, self()})
    Bridge.cast_msg(show_msg(id, view, opts))
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

  @doc "Bring a tab's window to front."
  def activate_tab(webview), do: Bridge.cast_msg(%{op: "activate_tab", webview: webview})

  @doc "Close a tab's window."
  def close_tab(webview), do: Bridge.cast_msg(%{op: "close_tab", webview: webview})

  # ---------------------------------------------------------------------

  @impl true
  def init(nil), do: {:ok, %{}}

  @impl true
  def handle_cast({:shown, id, view, opts, owner_pid}, state) do
    entry = %{
      id: id,
      title: Keyword.get(opts, :title, id),
      kind: to_string(Keyword.get(opts, :kind, :floating)),
      owner: owner_name(owner_pid),
      view: view,
      opts: opts,
      shown_at: System.system_time(:millisecond),
      closed: false
    }

    {:noreply, Map.put(state, id, entry)}
  end

  def handle_cast({:closed, id}, state) do
    {:noreply,
     case state do
       %{^id => entry} -> Map.put(state, id, %{entry | closed: true})
       _ -> state
     end}
  end

  @impl true
  def handle_call(:list, _from, state) do
    entries =
      state
      |> Map.values()
      |> Enum.sort_by(& &1.shown_at, :desc)
      |> Enum.map(&Map.take(&1, [:id, :title, :kind, :owner, :closed, :shown_at]))

    {:reply, entries, state}
  end

  def handle_call({:reshow, id}, _from, state) do
    case state do
      %{^id => entry} ->
        Bridge.cast_msg(show_msg(id, entry.view, entry.opts))
        {:reply, :ok, Map.put(state, id, %{entry | closed: false})}

      _ ->
        {:reply, {:error, :unknown}, state}
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
