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
    {:ok, %{tabs: %{}}}
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
        Logger.info("session: fresh engine — restoring #{length(remembered)} tabs")
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
end
