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
    id = BowserBrain.ModScope.surface_id(id)
    opts = Keyword.put(opts, :profile, BowserBrain.ModScope.current())
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
    id = BowserBrain.ModScope.surface_id(id)
    GenServer.cast(__MODULE__, {:closed, to_string(id)})
    Bridge.cast_msg(%{op: "surface", surface: "close", id: to_string(id)})
  end

  @doc "Every panel ever shown this brain-lifetime: id, title, kind, owner, closed."
  def list do
    entries = GenServer.call(__MODULE__, :list)
    case BowserBrain.ModScope.current() do
      nil -> entries
      profile -> entries |> Enum.filter(&(Map.get(&1, :profile) == profile))
        |> Enum.map(&Map.update!(&1, :id, fn id -> String.replace_prefix(id, "profile:#{profile}:", "") end))
    end
  catch
    :exit, _ -> []
  end

  @doc "Re-show a known panel from its stored view tree."
  def reshow(id) do
    GenServer.call(__MODULE__, {:reshow, BowserBrain.ModScope.surface_id(id)})
  catch
    :exit, _ -> {:error, :registry_down}
  end

  @doc """
  View-menu toggle: a visible panel is suppressed and closed (shows keep
  recording but stop reaching the engine); a hidden one is unsuppressed and
  re-shown from its stored view. Returns {:ok, :hidden | :shown}.
  """
  def toggle(id) do
    GenServer.call(__MODULE__, {:toggle, BowserBrain.ModScope.surface_id(id)})
  catch
    :exit, _ -> {:error, :registry_down}
  end

  @doc "Bring a tab's window to front."
  def activate_tab(webview), do: Bridge.cast_msg(%{op: "activate_tab", webview: webview})

  @doc "Close a tab's window."
  def close_tab(webview), do: Bridge.cast_msg(%{op: "close_tab", webview: webview})

  @doc "Create a background website tab in the target tab's window; returns {:ok, state} including created ID."
  def create_tab(webview, url) when is_binary(url), do: website_layout(webview, "create_tab", %{"url" => url})
  def create_tab(_, _), do: {:error, :invalid_url}

  @doc "Arrange 2–4 existing same-window tabs. Options: axis: :horizontal | :vertical, weights: list of 0.1..1 numbers."
  def layout_tabs(webview, tabs, opts \\ [])
  def layout_tabs(webview, tabs, opts) when is_list(tabs) and is_list(opts) do
    if Keyword.keyword?(opts) do
      axis = Keyword.get(opts, :axis, :horizontal)
      weights = Keyword.get(opts, :weights, Enum.map(tabs, fn _ -> 1.0 end))
      if length(tabs) in 2..4 and Enum.all?(tabs, &(is_integer(&1) and &1 > 0)) and
           length(Enum.uniq(tabs)) == length(tabs) and axis in [:horizontal, :vertical] and
           is_list(weights) and length(weights) == length(tabs) and
           Enum.all?(weights, &(is_number(&1) and &1 >= 0.1 and &1 <= 1)) do
        website_layout(webview, "set", %{"tabs" => tabs, "axis" => to_string(axis), "weights" => weights})
      else
        {:error, :invalid_layout}
      end
    else
      {:error, :invalid_layout}
    end
  end
  def layout_tabs(_, _, _), do: {:error, :invalid_layout}

  @doc "Inspect window tabs, visible panes, axis, current divider weights and active tab."
  def tab_layout(webview), do: website_layout(webview, "get", %{})

  @doc "Restore one visible page, retaining all tabs and their navigation state."
  def reset_layout(webview), do: website_layout(webview, "reset", %{})

  @doc false
  def website_layout(webview, action, args) when is_integer(webview) and webview > 0 and is_map(args) do
    profile = BowserBrain.ModScope.profile_of(webview)
    owner = BowserBrain.ModScope.current()
    if owner != nil and owner != profile do
      {:error, :wrong_profile}
    else
      message = args |> Map.take(["tabs", "axis", "weights", "url"])
        |> Map.merge(%{"webview" => webview, "profile" => profile, "action" => action})
      GenServer.call(Bridge, {:native_verify, "website_layout", message}, 5_000)
    end
  catch
    :exit, _ -> {:error, :layout_unavailable}
  end
  def website_layout(_, _, _), do: {:error, :invalid_webview}

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
    notify_menu()
    {:noreply, %{state | panels: panels}}
  end

  # Dismissal is core browser behavior, never dependent on an optional mod.
  def handle_info({:browser_event, %{"event" => "surface_dismiss", "surface" => id}}, state) do
    case state.panels[id] do
      nil -> {:noreply, state}
      _entry ->
        Bridge.cast_msg(%{op: "surface", surface: "close", id: id})
        state = %{state | suppressed: MapSet.put(state.suppressed, id)}
        {:noreply, update_entry(state, id, &%{&1 | closed: true})}
    end
  end

  def handle_info({:browser_event, %{"event" => "chrome_click", "id" => "surface_reopen:" <> id}}, state) do
    case handle_call({:reshow, id}, nil, state) do
      {:reply, _, state} -> {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast({:closed, id}, state) do
    {:noreply, update_entry(state, id, &%{&1 | closed: true})}
  end

  @impl true
  def handle_call({:shown, id, view, opts, owner_pid}, _from, state) do
    # Settings sections are not panels: a stale View-menu suppression from
    # when they floated must never swallow them.
    suppressed? = Keyword.get(opts, :kind, :floating) != :settings and MapSet.member?(state.suppressed, id)

    entry = %{
      id: id,
      title: Keyword.get(opts, :title, id),
      kind: to_string(Keyword.get(opts, :kind, :floating)),
      owner: owner_name(owner_pid),
      profile: Keyword.get(opts, :profile),
      view: view,
      opts: opts,
      shown_at: System.system_time(:millisecond),
      closed: suppressed?
    }

    notify_menu()
    {:reply, suppressed?, put_in(state.panels[id], entry)}
  end

  def handle_call(:list, _from, state) do
    entries =
      state.panels
      |> Map.values()
      |> Enum.sort_by(& &1.shown_at, :desc)
      |> Enum.map(fn e ->
        e
        |> Map.take([:id, :title, :kind, :owner, :closed, :shown_at, :profile])
        |> Map.put(:suppressed, MapSet.member?(state.suppressed, e.id))
      end)

    {:reply, entries, state}
  end

  def handle_call({:reshow, id}, _from, state) do
    case state.panels do
      %{^id => entry} ->
        BowserBrain.Chrome.remove_menu_item("surface_reopen:" <> id)
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
          BowserBrain.Chrome.remove_menu_item("surface_reopen:" <> id)
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

  defp notify_menu do
    if pid = Process.whereis(BowserBrain.PanelMenu), do: send(pid, :sync)
  end

  defp update_entry(state, id, fun) do
    notify_menu()
    case state.panels do
      %{^id => entry} -> put_in(state.panels[id], fun.(entry))
      _ -> state
    end
  end

  defp show_msg(id, view, opts) do
    %{
      op: "surface",
      profile: Keyword.get(opts, :profile),
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
      # kind: :settings — hosted as a section of the conventional Settings
      # window (⌘,) instead of a floating panel: section: sidebar label,
      # order: sort key, activate: bring the window up now.
      section: Keyword.get(opts, :section),
      order: Keyword.get(opts, :order, 50),
      activate: Keyword.get(opts, :activate, false),
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
