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

  alias BowserBrain.{Bridge, Browser, Chrome, Page, XAdapter}

  @poll_ms 800
  @default_timeout 15_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Fetch at least `want` tweets from a route. Scrolls the harness webview and
  accumulates deduped tweets past X's virtualizer (which recycles offscreen
  cells) until it has `want`, the feed stalls, or the deadline. Same route
  as last time extends the existing river instead of reloading.
  """
  def fetch(route, want \\ 15, timeout \\ @default_timeout) do
    GenServer.call(__MODULE__, {:fetch, route, want, timeout}, timeout + 3_000)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl true
  def init(nil) do
    {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
    # wv: harness webview id; route/river: the current route and its
    # accumulated deduped tweets (so a bigger `want` on the same route
    # extends rather than reloads); busy/queue: serialize fetches.
    {:ok, %{wv: nil, awaiting: false, busy: false, queue: :queue.new(), route: nil, river: []}}
  end

  @impl true
  def handle_call({:fetch, route, want, timeout}, from, state) do
    job = {from, route, want, timeout}

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

  def handle_info({:done, from, route, river}, state) do
    GenServer.reply(from, {:ok, river})
    {:noreply, dequeue(%{state | busy: false, route: route, river: river})}
  end

  def handle_info({:failed, from, reason}, state) do
    GenServer.reply(from, {:error, reason})
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

  defp run({from, route, want, timeout}, %{wv: wv} = state) do
    # Defensive against a hot-swap that kept the old state shape (no
    # route/river keys) — new keys are read via Map.get for one release.
    same_route = route == Map.get(state, :route)
    existing = if same_route, do: Map.get(state, :river, []), else: []

    unless same_route do
      # Fresh route: load it, warm-mount so WebKit actually renders the
      # JS-heavy timeline (unmounted webviews defer rendering — the media-
      # dubber lesson), and reset the scroll position.
      Browser.navigate(route_url(route), wv)
    end

    Bridge.cast_msg(%{op: "warm_tab", webview: wv, ms: timeout})
    parent = self()
    deadline = System.monotonic_time(:millisecond) + timeout

    Task.start(fn ->
      case paginate(wv, existing, want, deadline, same_route, 0) do
        {:ok, river} -> send(parent, {:done, from, route, river})
        {:error, reason} -> send(parent, {:failed, from, reason})
      end
    end)

    %{state | busy: true}
  end

  # Scroll-and-accumulate: extract the rendered tweets, merge them into the
  # river (deduped by id), scroll the harness down a screen, repeat — until
  # we have `want`, the feed stops growing (end / rate-limit), or we hit the
  # deadline. X's virtualizer recycles offscreen cells, so we MUST extract
  # before scrolling past them (the plurk-era lesson, applied here).
  defp paginate(wv, river, want, deadline, scrolled?, dry) do
    river =
      case XAdapter.timeline(wv) do
        {:ok, fresh} -> merge(river, fresh)
        _ -> river
      end

    cond do
      length(river) >= want ->
        {:ok, Enum.take(river, want)}

      System.monotonic_time(:millisecond) >= deadline ->
        if river == [], do: {:error, :timeout}, else: {:ok, river}

      # Two scrolls with no new tweets = the end of what X will give us.
      dry >= 2 and scrolled? ->
        {:ok, river}

      true ->
        grew = length(river)
        scroll(wv)
        Process.sleep(@poll_ms)
        after_river =
          case XAdapter.timeline(wv) do
            {:ok, fresh} -> merge(river, fresh)
            _ -> river
          end

        next_dry = if length(after_river) > grew, do: 0, else: dry + 1
        paginate(wv, after_river, want, deadline, true, next_dry)
    end
  end

  defp scroll(wv) do
    Page.eval(
      "(document.scrollingElement||document.documentElement).scrollTop += Math.round(innerHeight*0.9)",
      webview: wv
    )
  catch
    :exit, _ -> :ok
  end

  # Append tweets not already in the river, preserving first-seen order.
  defp merge(river, fresh) do
    seen = MapSet.new(river, &tweet_key/1)

    added =
      fresh
      |> Enum.reject(&MapSet.member?(seen, tweet_key(&1)))
      |> Enum.uniq_by(&tweet_key/1)

    river ++ added
  end

  defp tweet_key(t), do: t.id || t.permalink || t.text

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
