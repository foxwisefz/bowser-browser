defmodule BowserBrain.Session do
  @moduledoc """
  Session resurrection (bowser-browser-7qq): the brain is the browser's
  memory. Mirrors open tabs from events it already receives; when a FRESH
  engine says hello (blank tabs) and we remember a session, we rebuild it —
  first remembered URL into the existing webview, the rest as new tabs.
  When the engine says hello WITH real tabs (brain restarted, engine didn't),
  we adopt the engine's state instead.

  The active tab is part of the session (bowser-browser-p7l): tab_activated
  events keep it current, it persists to disk as an index into the url list,
  and a restore re-activates it once its webview exists — coming back from a
  crash lands you on the tab you were on, not the leftmost one.
  """
  use GenServer
  require Logger

  alias BowserBrain.{Bridge, Browser, Surface}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Currently remembered tabs, ordered by webview id."
  def tabs, do: GenServer.call(__MODULE__, {:tabs, BowserBrain.ModScope.current()})

  @doc "The mirrored URL of one webview (nil when unknown). Cheap call; used by host-scoped mods."
  def url_of(webview) do
    GenServer.call(__MODULE__, {:url_of, webview})
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(nil) do
    {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
    # cookies: %{origin => %{url: sample_url, cookies: [map]}} — snapshotted
    # from the living engine, replayed into a fresh one BEFORE tabs navigate,
    # so restored pages load already logged in. Brain memory only: secrets
    # never touch disk (ADR 0004 territory).
    # disk: %{tabs: [...], active: index} persisted at ~/.bowser/session.json
    # so a FULL-stack restart (brain + engine dying together) still restores
    # tabs. Logins survive via WebKit's own on-disk store.
    # restore: %{remaining: n} — counts tab_opened events after a restore
    # until the remembered active tab's webview appears, then activates it.
    # profiles: %{webview => profile id} — which window family a tab lives in.
    {:ok, %{tabs: %{}, active: nil, cookies: %{}, disk: load_disk(), restore: nil, profiles: %{}}}
  end

  @impl true
  def handle_call({:tabs, profile}, _from, state) do
    tabs = if is_nil(profile), do: state.tabs, else: Map.filter(state.tabs, fn {id, _} -> Map.get(state.profiles, id, "default") == profile end)
    {:reply, ordered_urls(tabs), state}
  end

  def handle_call(:tabs, _from, state) do
    {:reply, ordered_urls(state.tabs), state}
  end

  def handle_call({:url_of, webview}, _from, state) do
    {:reply, state.tabs[webview], state}
  end

  # Flush before AppKit tears down any windows, then ignore teardown events.
  def handle_call(:prepare_quit, _from, state) do
    state = persist(state)
    {:reply, :ok, Map.put(state, :quitting, true)}
  end

  def handle_info({:browser_event, _event}, %{quitting: true} = state),
    do: {:noreply, state}

  @impl true
  def handle_info({:browser_event, %{"event" => "url_changed", "webview" => wv, "url" => url}}, state) do
    {:noreply, persist(%{state | tabs: Map.put(state.tabs, wv, url)})}
  end

  def handle_info({:browser_event, %{"event" => "webview_closed", "webview" => wv}}, state) do
    active = if state.active == wv, do: nil, else: state.active
    profiles = Map.delete(Map.get(state, :profiles, %{}), wv)
    {:noreply, persist(%{state | tabs: Map.delete(state.tabs, wv), active: active} |> Map.put(:profiles, profiles))}
  end

  def handle_info({:browser_event, %{"event" => "tab_activated", "webview" => wv}}, state) do
    {:noreply, persist(%{state | active: wv})}
  end

  # A restore is in flight: each tab_opened is one of our open_tab casts
  # Launch URLs remain open; seed restored URLs immediately so an interrupted
  # load or quit cannot replace the saved session with a partial restore.
  def handle_info({:browser_event, %{"event" => "tab_opened", "webview" => wv}},
                  %{pending_restore: [entry | rest]} = state) do
    state = state |> note_profile(wv, entry.profile)
    {:noreply, persist(%{state | tabs: Map.put(state.tabs, wv, entry.url), pending_restore: rest})}
  end

  # coming back with its webview id. When the countdown hits the remembered
  # active tab, put it on screen.
  def handle_info(
        {:browser_event, %{"event" => "tab_opened", "webview" => wv} = ev},
        %{restore: %{remaining: n}} = state
      ) do
    state = note_profile(state, wv, ev["profile"])

    case n - 1 do
      0 ->
        Logger.info("session: restore complete — activating webview #{wv}")
        Surface.activate_tab(wv)
        # The shell's freeze-frame holds until the RESTORED ACTIVE tab
        # paints — dismissing on any earlier paint shows a mid-restore
        # double-switch (bowser-browser-6fa).
        Bridge.cast_msg(%{op: "restore_done", webview: wv})
        {:noreply, %{state | restore: nil}}

      left ->
        {:noreply, %{state | restore: %{remaining: left}}}
    end
  end

  def handle_info({:browser_event, %{"event" => "tab_opened", "webview" => wv} = ev}, state) do
    {:noreply, note_profile(state, wv, ev["profile"])}
  end

  # Page finished loading: snapshot its origin's cookie jar.
  def handle_info({:browser_event, %{"event" => "load_status", "status" => 2, "webview" => wv}}, state) do
    with url when is_binary(url) <- state.tabs[wv],
         origin when is_binary(origin) <- origin_of(url),
         {:ok, cookies} <- safe_get_cookies(url) do
      {:noreply, put_in(state.cookies[origin], %{url: url, cookies: cookies})}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:browser_event, %{"event" => "hello"} = hello}, state) do
    engine_tabs = Map.get(hello, "tabs", [])
    engine_urls = for %{"url" => u} <- engine_tabs, real_url?(u), do: u
    remembered = ordered_urls(state.tabs)
    engine_id = hello["engine_session_id"]
    previous_id = Map.get(state, :engine_session_id) || Map.get(state.disk, :engine_session_id)
    fresh_engine = is_binary(engine_id) and engine_id != previous_id
    saved = if remembered == [], do: disk_entries(state.disk), else: entries(state)
    state = if is_binary(engine_id), do: Map.put(state, :engine_session_id, engine_id), else: state

    cond do
      fresh_engine and engine_urls != [] and saved != [] ->
        missing = missing_entries(saved, engine_tabs)
        Logger.info("session: fresh engine with launch URLs — restoring #{length(missing)} missing tabs")
        adopted = for %{"id" => id, "url" => u} <- engine_tabs, real_url?(u), into: %{}, do: {id, u}
        profiles = for %{"id" => id} = t <- engine_tabs, into: %{}, do: {id, t["profile"] || "default"}
        state = state |> Map.put(:tabs, adopted) |> Map.put(:profiles, profiles)
          |> Map.put(:active, hello["active"]) |> Map.put(:pending_restore, missing)
        # Persist all pending entries before asking WebKit to open any of them.
        state = persist(state)
        BowserBrain.UserContent.push_now()
        for entry <- missing do
          Bridge.cast_msg(%{op: "chrome", chrome: "open_tab", url: entry.url, profile: entry.profile})
        end
        Bridge.cast_msg(%{op: "restore_done", webview: hello["active"] || 0})
        {:noreply, state}

      engine_urls != [] ->
        Logger.info("session: adopting engine state (#{length(engine_urls)} tabs)")
        adopted =
          for %{"id" => id, "url" => u} <- engine_tabs, real_url?(u), into: %{}, do: {id, u}

        profiles = for %{"id" => id} = t <- engine_tabs, is_binary(t["profile"]), into: %{}, do: {id, t["profile"]}

        {:noreply,
         persist(%{state | tabs: adopted, active: Map.get(hello, "active", state.active)} |> Map.put(:profiles, profiles))}

      # Full-stack restart: brain memory is empty but disk remembers.
      remembered == [] and engine_urls == [] and state.disk.urls != [] ->
        Logger.info(
          "session: full-stack restart — restoring #{length(state.disk.urls)} tabs from disk"
        )

        # Styles BEFORE navigations, deterministically (bowser-browser-6eu).
        BowserBrain.UserContent.push_now()
        restore = rebuild(disk_entries(state.disk), state.disk.active, engine_tabs)
        {:noreply, %{state | restore: restore}}

      remembered != [] ->
        cookie_count =
          state.cookies |> Enum.map(fn {_o, %{cookies: c}} -> length(c) end) |> Enum.sum()

        Logger.info(
          "session: fresh engine — replaying #{cookie_count} cookies, restoring #{length(remembered)} tabs"
        )

        # Styles BEFORE navigations, deterministically (bowser-browser-6eu),
        # and cookies first, so restored tabs load logged in AND styled.
        BowserBrain.UserContent.push_now()

        for {_origin, %{url: url, cookies: cookies}} <- state.cookies,
            cookie <- cookies,
            do: Bridge.set_cookie(url, cookie)

        restore = rebuild(entries(state), active_index(state.tabs, state.active), engine_tabs)
        # Old ids are meaningless now; url_changed events rebuild the map.
        {:noreply, %{state | tabs: %{}, active: nil, restore: restore} |> Map.put(:profiles, %{})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Rebuild a remembered session into a fresh engine. The engine starts with
  # ONE window (default profile) holding one blank webview: the first
  # default-profile tab loads there; everything else is opened as a tab —
  # with its profile, so the shell routes it to (or creates) that profile's
  # window. Returns the restore countdown (nil when the visible first tab IS
  # the active one).
  defp rebuild(entries, active_idx, engine_tabs) do
    first_webview = engine_tabs |> Enum.map(& &1["id"]) |> Enum.min(fn -> 0 end)
    {first, rest, remaining} = restore_plan(entries, active_idx)

    if first, do: Browser.navigate(first, first_webview)

    for %{url: url, profile: profile} <- rest do
      Bridge.cast_msg(%{op: "chrome", chrome: "open_tab", url: url, profile: profile})
    end

    case remaining do
      0 ->
        Bridge.cast_msg(%{op: "restore_done", webview: first_webview})
        nil

      n ->
        %{remaining: n}
    end
  end

  @doc """
  Plan a restore: `{first_url | nil, rest_entries, remaining}`. The first
  DEFAULT-profile entry is pulled to the front (it loads into the engine's
  existing default window); `remaining` is how many `tab_opened` events
  precede the remembered active tab (0 = it is the first/visible one).
  Public for tests.
  """
  def restore_plan(entries, active_idx) do
    entries = Enum.map(entries, &normalize_entry/1)
    active = Enum.at(entries, min(max(active_idx, 0), max(length(entries) - 1, 0)))

    case Enum.find_index(entries, &(&1.profile == "default")) do
      nil ->
        # No default tab: the blank first webview stays; the active one is
        # the nth open_tab (1-based).
        {nil, entries, (Enum.find_index(entries, &(&1 == active)) || 0) + 1}

      i ->
        first = Enum.at(entries, i)
        rest = List.delete_at(entries, i)
        remaining = if active == first, do: 0, else: (Enum.find_index(rest, &(&1 == active)) || 0) + 1
        {first.url, rest, remaining}
    end
  end

  defp disk_entries(%{tabs: tabs}) when is_list(tabs), do: tabs
  defp disk_entries(_), do: []

  @doc "Saved tabs absent from the launch snapshot, matching profile and URL with multiplicity."
  def missing_entries(saved, engine_tabs) do
    available = engine_tabs |> Enum.map(&{&1["profile"] || "default", &1["url"]}) |> Enum.frequencies()
    {missing, _} = Enum.reduce(saved, {[], available}, fn entry, {missing, counts} ->
      key = {entry.profile, entry.url}
      case Map.get(counts, key, 0) do
        0 -> {[entry | missing], counts}
        n -> {missing, Map.put(counts, key, n - 1)}
      end
    end)
    Enum.reverse(missing)
  end

  defp normalize_entry(%{url: u, profile: p}), do: %{url: u, profile: p || "default"}
  defp normalize_entry(%{"url" => u} = e), do: %{url: u, profile: e["profile"] || "default"}

  defp note_profile(state, wv, profile) when is_binary(profile),
    do: Map.put(state, :profiles, Map.put(Map.get(state, :profiles, %{}), wv, profile))

  defp note_profile(state, _wv, _none), do: state

  # Remembered tabs as %{url, profile} entries, ordered by webview id.
  defp entries(state) do
    profiles = Map.get(state, :profiles, %{})
    for {id, url} <- real_tabs(state.tabs), do: %{url: url, profile: Map.get(profiles, id, "default")}
  end

  defp ordered_urls(tabs) do
    tabs
    |> real_tabs()
    |> Enum.map(fn {_id, url} -> url end)
  end

  # Position of the active webview in the remembered ordering — what an
  # `open_tab` countdown and the on-disk index both mean by "active".
  defp active_index(tabs, active) do
    tabs
    |> real_tabs()
    |> Enum.find_index(fn {id, _url} -> id == active end)
    |> Kernel.||(0)
  end

  defp real_tabs(tabs) do
    tabs
    |> Enum.sort()
    |> Enum.filter(fn {_id, url} -> real_url?(url) end)
  end

  # http(s) and local file:// pages both count as real, restorable tabs.
  defp real_url?(u), do: is_binary(u) and (String.starts_with?(u, "http") or String.starts_with?(u, "file:"))

  defp disk_path do
    Application.get_env(
      :bowser_brain,
      :session_path,
      Path.join(BowserBrain.Paths.home(), "session.json")
    )
  end

  @doc false
  # Public for tests. Reads the tab records and active index written by persist/1.
  def load_disk do
    with {:ok, raw} <- File.read(disk_path()),
         {:ok, decoded} <- JSON.decode(raw) do
      case decoded do
        %{"tabs" => tabs, "active" => active} = stored when is_list(tabs) ->
          tabs = for %{"url" => u} = t <- tabs, real_url?(u), do: %{url: u, profile: t["profile"] || "default"}
          Map.put(disk(tabs, active), :engine_session_id, stored["engine_session_id"])

        _ ->
          disk([], 0)
      end
    else
      _ -> disk([], 0)
    end
  end

  # Cache URLs for restore logging and the session query API.
  defp disk(tabs, active) do
    active = if is_integer(active) and active in 0..max(length(tabs) - 1, 0), do: active, else: 0
    %{tabs: tabs, urls: Enum.map(tabs, & &1.url), active: active}
  end

  defp persist(state) do
    tabs = entries(state) ++ Map.get(state, :pending_restore, [])
    urls = Enum.map(tabs, & &1.url)

    if urls != [] do
      path = disk_path()
      temporary = path <> ".tmp"
      File.write!(temporary, JSON.encode!(%{tabs: tabs, active: active_index(state.tabs, state.active),
                                          engine_session_id: Map.get(state, :engine_session_id)}))
      File.rename!(temporary, path)
    end

    state
  end

  defp origin_of(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://#{host}"

      _ ->
        nil
    end
  end

  defp safe_get_cookies(url) do
    Bridge.get_cookies(url)
  catch
    :exit, _ -> {:error, :timeout}
  end
end
