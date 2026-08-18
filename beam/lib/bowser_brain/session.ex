defmodule BowserBrain.Session do
  @moduledoc """
  Session resurrection (bowser-browser-7qq): the brain is the browser's
  memory. Mirrors open tabs from events it already receives; when a FRESH
  engine says hello (blank tabs) and we remember a session, we rebuild it —
  first remembered URL into the existing webview, the rest as new tabs.
  When the engine says hello WITH real tabs (brain restarted, engine didn't),
  we adopt the engine's state instead.
  """
  use GenServer
  require Logger

  alias BowserBrain.{Bridge, Browser}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Currently remembered tabs, ordered by webview id."
  def tabs, do: GenServer.call(__MODULE__, :tabs)

  @impl true
  def init(nil) do
    {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
    # cookies: %{origin => %{url: sample_url, cookies: [map]}} — snapshotted
    # from the living engine, replayed into a fresh one BEFORE tabs navigate,
    # so restored pages load already logged in. Brain memory only: secrets
    # never touch disk (ADR 0004 territory).
    # disk: URLs persisted at ~/.bowser/session.json so a FULL-stack restart
    # (brain + engine dying together) still restores tabs. Logins survive
    # via WebKit's own on-disk store, so urls are all we need.
    {:ok, %{tabs: %{}, cookies: %{}, disk: load_disk()}}
  end

  @impl true
  def handle_call(:tabs, _from, state) do
    {:reply, ordered_urls(state.tabs), state}
  end

  @impl true
  def handle_info({:browser_event, %{"event" => "url_changed", "webview" => wv, "url" => url}}, state) do
    {:noreply, persist(%{state | tabs: Map.put(state.tabs, wv, url)})}
  end

  def handle_info({:browser_event, %{"event" => "webview_closed", "webview" => wv}}, state) do
    {:noreply, persist(%{state | tabs: Map.delete(state.tabs, wv)})}
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

        {:noreply, persist(%{state | tabs: adopted})}

      # Full-stack restart: brain memory is empty but disk remembers.
      remembered == [] and engine_urls == [] and state.disk != [] ->
        Logger.info("session: full-stack restart — restoring #{length(state.disk)} tabs from disk")
        [first | rest] = state.disk
        first_webview = engine_tabs |> Enum.map(& &1["id"]) |> Enum.min(fn -> 0 end)
        Browser.navigate(first, first_webview)
        for url <- rest, do: Bridge.cast_msg(%{op: "chrome", chrome: "open_tab", url: url})
        {:noreply, state}

      remembered != [] ->
        cookie_count =
          state.cookies |> Enum.map(fn {_o, %{cookies: c}} -> length(c) end) |> Enum.sum()

        Logger.info(
          "session: fresh engine — replaying #{cookie_count} cookies, restoring #{length(remembered)} tabs"
        )

        # Cookies first, so restored tabs load logged in.
        for {_origin, %{url: url, cookies: cookies}} <- state.cookies,
            cookie <- cookies,
            do: Bridge.set_cookie(url, cookie)

        [first | rest] = remembered
        first_webview = engine_tabs |> Enum.map(& &1["id"]) |> Enum.min(fn -> 0 end)
        Browser.navigate(first, first_webview)
        for url <- rest, do: Bridge.cast_msg(%{op: "chrome", chrome: "open_tab", url: url})
        # Old ids are meaningless now; url_changed events rebuild the map.
        {:noreply, %{state | tabs: %{}}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp ordered_urls(tabs) do
    tabs
    |> Enum.sort()
    |> Enum.map(fn {_id, url} -> url end)
    |> Enum.filter(&real_url?/1)
  end

  defp real_url?(u), do: is_binary(u) and String.starts_with?(u, "http")

  defp disk_path, do: Path.join(System.user_home!(), ".bowser/session.json")

  defp load_disk do
    with {:ok, raw} <- File.read(disk_path()),
         {:ok, urls} when is_list(urls) <- JSON.decode(raw) do
      Enum.filter(urls, &real_url?/1)
    else
      _ -> []
    end
  end

  defp persist(state) do
    urls = ordered_urls(state.tabs)
    if urls != [], do: File.write(disk_path(), JSON.encode!(urls))
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
