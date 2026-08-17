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
    {:ok, %{tabs: %{}, cookies: %{}}}
  end

  @impl true
  def handle_call(:tabs, _from, state) do
    {:reply, ordered_urls(state.tabs), state}
  end

  @impl true
  def handle_info({:browser_event, %{"event" => "url_changed", "webview" => wv, "url" => url}}, state) do
    {:noreply, %{state | tabs: Map.put(state.tabs, wv, url)}}
  end

  def handle_info({:browser_event, %{"event" => "webview_closed", "webview" => wv}}, state) do
    {:noreply, %{state | tabs: Map.delete(state.tabs, wv)}}
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

        {:noreply, %{state | tabs: adopted}}

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
