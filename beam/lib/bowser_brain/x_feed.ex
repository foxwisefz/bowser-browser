defmodule BowserBrain.XFeed do
  @moduledoc """
  Headless X feed harness (bowser-browser-2q2): the data engine behind the
  generated-native-app vision (ADR 0011). Owns ONE dedicated background
  webview and navigates it — with a real page load, not the SPA nav the
  x.com router fights — to any X route, then extracts the rendered timeline
  via `BowserBrain.XAdapter`.

      XFeed.fetch("home")            #=> {:ok, [tweet, ...]}
      XFeed.fetch("@tealtoronto")    #=> a profile's tweets
      XFeed.fetch("search:elixir")   #=> search results

  Sequential by design: one harness webview, one navigation at a time.
  Concurrent callers queue.
  """
  use GenServer
  require Logger

  alias BowserBrain.{Bridge, Browser, Chrome, XAdapter}

  @poll_ms 800
  @default_timeout 15_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Fetch a route's timeline as normalized tweets."
  def fetch(route, timeout \\ @default_timeout) do
    GenServer.call(__MODULE__, {:fetch, route, timeout}, timeout + 3_000)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl true
  def init(nil) do
    {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
    # wv: the harness webview id (nil until acquired); busy: an in-flight
    # fetch; queue: callers waiting for the webview or for the current fetch.
    {:ok, %{wv: nil, awaiting: false, busy: false, queue: :queue.new()}}
  end

  @impl true
  def handle_call({:fetch, route, timeout}, from, state) do
    job = {from, route, timeout}

    cond do
      state.wv == nil and not state.awaiting ->
        # First fetch: spin up the harness tab, then run this job on it.
        Chrome.open_tab("https://x.com/home", activate: false)
        {:noreply, %{state | awaiting: true, queue: :queue.in(job, state.queue)}}

      state.wv == nil or state.busy ->
        {:noreply, %{state | queue: :queue.in(job, state.queue)}}

      true ->
        {:noreply, run(job, state)}
    end
  end

  @impl true
  def handle_info({:browser_event, %{"event" => "tab_opened", "webview" => wv}}, %{awaiting: true, wv: nil} = state) do
    Logger.info("xfeed: harness webview #{wv} acquired")
    {:noreply, dequeue(%{state | wv: wv, awaiting: false})}
  end

  def handle_info({:done, from, result}, state) do
    GenServer.reply(from, result)
    {:noreply, dequeue(%{state | busy: false})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- internals --------------------------------------------------------------

  defp dequeue(%{busy: true} = state), do: state

  defp dequeue(state) do
    case :queue.out(state.queue) do
      {{:value, job}, rest} -> run(job, %{state | queue: rest})
      {:empty, _} -> state
    end
  end

  defp run({from, route, timeout}, %{wv: wv} = state) do
    url = route_url(route)
    Browser.navigate(url, wv)
    # WebKit DEFERS rendering for unmounted (background) webviews — X's
    # JS-heavy timeline may never paint in a purely background harness tab
    # (the same lesson the media dubber hit). warm_tab briefly mounts it
    # invisibly so the DOM renders and XAdapter can read it.
    Bridge.cast_msg(%{op: "warm_tab", webview: wv, ms: timeout})
    parent = self()
    deadline = System.monotonic_time(:millisecond) + timeout

    Task.start(fn ->
      result = poll(wv, deadline)
      send(parent, {:done, from, result})
    end)

    %{state | busy: true}
  end

  # Poll until the feed renders tweets (or the deadline). A rendered-but-empty
  # timeline is rare; we accept the first non-empty extraction.
  defp poll(wv, deadline) do
    case XAdapter.timeline(wv) do
      {:ok, [_ | _] = tweets} ->
        {:ok, tweets}

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@poll_ms)
          poll(wv, deadline)
        else
          {:error, :timeout}
        end
    end
  end

  @doc """
  Map a route token to an x.com URL. Pure.

  - "home"              -> /home
  - "@handle"           -> /handle
  - "@handle/likes"     -> /handle/likes
  - "search:query"      -> /search?q=query (live tab)
  - anything with a "/" -> passed through as a path
  """
  def route_url("home"), do: "https://x.com/home"

  def route_url("search:" <> query) do
    "https://x.com/search?q=" <> URI.encode(String.trim(query)) <> "&f=live"
  end

  def route_url("@" <> rest), do: "https://x.com/" <> rest

  def route_url(route) when is_binary(route) do
    "https://x.com/" <> String.trim_leading(route, "/")
  end
end
