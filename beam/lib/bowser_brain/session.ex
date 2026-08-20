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
  def tabs, do: GenServer.call(__MODULE__, :tabs)

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
    # disk: %{urls: [...], active: index} persisted at ~/.bowser/session.json
    # so a FULL-stack restart (brain + engine dying together) still restores
    # tabs. Logins survive via WebKit's own on-disk store.
    # restore: %{remaining: n} — counts tab_opened events after a restore
    # until the remembered active tab's webview appears, then activates it.
    {:ok, %{tabs: %{}, active: nil, cookies: %{}, disk: load_disk(), restore: nil}}
  end

  @impl true
  def handle_call(:tabs, _from, state) do
    {:reply, ordered_urls(state.tabs), state}
  end

  def handle_call({:url_of, webview}, _from, state) do
    {:reply, state.tabs[webview], state}
  end

  @impl true
  def handle_info({:browser_event, %{"event" => "url_changed", "webview" => wv, "url" => url}}, state) do
    {:noreply, persist(%{state | tabs: Map.put(state.tabs, wv, url)})}
  end

  def handle_info({:browser_event, %{"event" => "webview_closed", "webview" => wv}}, state) do
    active = if state.active == wv, do: nil, else: state.active
    {:noreply, persist(%{state | tabs: Map.delete(state.tabs, wv), active: active})}
  end

  def handle_info({:browser_event, %{"event" => "tab_activated", "webview" => wv}}, state) do
    {:noreply, persist(%{state | active: wv})}
  end

  # A restore is in flight: each tab_opened is one of our open_tab casts
  # coming back with its webview id. When the countdown hits the remembered
  # active tab, put it on screen.
  def handle_info(
        {:browser_event, %{"event" => "tab_opened", "webview" => wv}},
        %{restore: %{remaining: n}} = state
      ) do
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

    cond do
      engine_urls != [] ->
        Logger.info("session: adopting engine state (#{length(engine_urls)} tabs)")
        adopted =
          for %{"id" => id, "url" => u} <- engine_tabs, real_url?(u), into: %{}, do: {id, u}

        {:noreply, persist(%{state | tabs: adopted, active: Map.get(hello, "active", state.active)})}

      # Full-stack restart: brain memory is empty but disk remembers.
      remembered == [] and engine_urls == [] and state.disk.urls != [] ->
        Logger.info(
          "session: full-stack restart — restoring #{length(state.disk.urls)} tabs from disk"
        )

        # Styles BEFORE navigations, deterministically (bowser-browser-6eu).
        BowserBrain.UserContent.push_now()
        restore = rebuild(state.disk.urls, state.disk.active, engine_tabs)
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

        restore = rebuild(remembered, active_index(state.tabs, state.active), engine_tabs)
        # Old ids are meaningless now; url_changed events rebuild the map.
        {:noreply, %{state | tabs: %{}, active: nil, restore: restore}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Rebuild a remembered session into a fresh engine: first URL into the
  # webview the engine already has, the rest as background tabs. Returns the
  # restore countdown (nil when the visible first tab IS the active one).
  defp rebuild([first | rest], active_idx, engine_tabs) do
    first_webview = engine_tabs |> Enum.map(& &1["id"]) |> Enum.min(fn -> 0 end)
    Browser.navigate(first, first_webview)
    for url <- rest, do: Bridge.cast_msg(%{op: "chrome", chrome: "open_tab", url: url})

    case min(active_idx, length(rest)) do
      0 ->
        # The visible first tab IS the active one: restore is complete the
        # moment it paints.
        Bridge.cast_msg(%{op: "restore_done", webview: first_webview})
        nil

      n ->
        %{remaining: n}
    end
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

  defp real_url?(u), do: is_binary(u) and String.starts_with?(u, "http")

  defp disk_path do
    Application.get_env(
      :bowser_brain,
      :session_path,
      Path.join(System.user_home!(), ".bowser/session.json")
    )
  end

  @doc false
  # Public for tests. Accepts the current %{urls, active} format and the
  # legacy bare url list (active defaults to 0 either way on bad data).
  def load_disk do
    with {:ok, raw} <- File.read(disk_path()),
         {:ok, decoded} <- JSON.decode(raw) do
      case decoded do
        %{"urls" => urls, "active" => active} when is_list(urls) ->
          urls = Enum.filter(urls, &real_url?/1)
          active = if is_integer(active) and active in 0..max(length(urls) - 1, 0), do: active, else: 0
          %{urls: urls, active: active}

        urls when is_list(urls) ->
          %{urls: Enum.filter(urls, &real_url?/1), active: 0}

        _ ->
          %{urls: [], active: 0}
      end
    else
      _ -> %{urls: [], active: 0}
    end
  end

  defp persist(state) do
    urls = ordered_urls(state.tabs)

    if urls != [] do
      File.write(
        disk_path(),
        JSON.encode!(%{urls: urls, active: active_index(state.tabs, state.active)})
      )
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
