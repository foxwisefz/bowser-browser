defmodule BowserBrain.Bridge do
  @moduledoc """
  Connection to the engine host over the Unix socket at ~/.bowser/brain.sock
  ({packet,4} frames, JSON payloads — ADR 0007). Reconnects forever: the
  browser can restart without restarting the brain, and vice versa.

  Events from the engine are broadcast to every subscriber in the
  BowserBrain.Events registry as `{:browser_event, map}`.
  """
  use GenServer
  require Logger

  # Fast reconnect: during a blue-green roll this delay is dead time between
  # the old engine dying and restore/panels reappearing in the new one.
  @reconnect_ms 250

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Fire-and-forget message to the engine."
  def cast_msg(map) when is_map(map), do: GenServer.cast(__MODULE__, {:send, map})

  @doc "Evaluate JS in a webview and wait for the result."
  def eval_js(webview, code, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:eval_js, webview, code}, timeout)
  end

  def eval_site_js(app, code, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:eval_site_js, app, code}, timeout)
  end

  @doc "Engine-level cookie read for a URL (includes HttpOnly)."
  def get_cookies(url, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:get_cookies, url}, timeout)
  end

  @doc "Engine-level cookie write (HTTP source, so HttpOnly replays too)."
  def set_cookie(url, cookie) when is_map(cookie) do
    cast_msg(%{op: "set_cookie", url: url, cookie: cookie})
  end

  def socket_path, do: Path.join(System.get_env("BOWSER_RELAY_DIR") || BowserBrain.Paths.home(), "brain.sock")

  @doc "Is the engine currently connected?"
  def connected?, do: GenServer.call(__MODULE__, :connected?)

  @impl true
  def init(nil) do
    # Hermetic tests never touch the live engine (bowser-browser-is4): a
    # test VM once won the socket race during an engine roll and test casts
    # navigated the owner's real tabs.
    if Application.get_env(:bowser_brain, :connect_bridge, true), do: send(self(), :connect)
    {:ok, %{sock: nil, pending: %{}, next_id: 1}}
  end

  @impl true
  def handle_info(:connect, state) do
    path = socket_path() |> String.to_charlist()

    case :gen_tcp.connect({:local, path}, 0, [:binary, packet: 4, active: true]) do
      {:ok, sock} ->
        Logger.info("bridge: connected to engine")
        {:noreply, %{state | sock: sock}}

      {:error, reason} ->
        Logger.debug("bridge: engine not up (#{inspect(reason)}), retrying")
        Process.send_after(self(), :connect, @reconnect_ms)
        {:noreply, state}
    end
  end

  def handle_info({:tcp, _sock, data}, state) do
    state =
      case JSON.decode(data) do
        {:ok, %{"op" => "handoff_barrier", "id" => id}} ->
          send_frame(state.sock, %{op: "handoff_barrier", id: id})
          state
        {:ok, %{"op" => "handoff_attached"}} ->
          send_frame(state.sock, %{op: "handoff_attached"})
          state

        {:ok, %{"op" => "app_quit"}} ->
          # A worker avoids deadlocking Engine's liveness call back into Bridge.
          # First flush Session here: all earlier broadcasts came from this process.
          :ok = GenServer.call(BowserBrain.Session, :prepare_quit)
          unless Map.get(state, :quitting, false) do
            Task.start(fn ->
              :ok = GenServer.call(BowserBrain.Engine, :prepare_quit)
              cast_msg(%{op: "quit_ready"})
              Process.sleep(100)
              System.stop(0)
            end)
          end
          Map.put(state, :quitting, true)

        {:ok, %{"op" => "event"} = event} ->
          broadcast(event)
          state

        {:ok, %{"op" => "js_result", "id" => id} = result} ->
          {from, pending} = Map.pop(state.pending, id)
          if from, do: GenServer.reply(from, js_reply(result))
          %{state | pending: pending}

        {:ok, %{"op" => "cookies_result", "id" => id} = result} ->
          {from, pending} = Map.pop(state.pending, id)
          if from, do: GenServer.reply(from, {:ok, Map.get(result, "cookies", [])})
          %{state | pending: pending}

        {:ok, %{"op" => "hello", "v" => v} = hello} ->
          Logger.info(
            "bridge: engine hello, protocol v#{v}, webviews #{inspect(hello["webviews"])}"
          )

          broadcast(Map.put(hello, "event", "hello"))
          state

        {:ok, other} ->
          Logger.warning("bridge: unknown message #{inspect(other)}")
          state

        {:error, reason} ->
          Logger.warning("bridge: bad JSON from engine: #{inspect(reason)}")
          state
      end

    {:noreply, state}
  end

  def handle_info({:tcp_closed, _sock}, state) do
    Logger.info("bridge: engine disconnected, retrying")
    Process.send_after(self(), :connect, @reconnect_ms)
    {:noreply, %{state | sock: nil}}
  end

  def handle_info({:tcp_error, _sock, _reason}, state) do
    Process.send_after(self(), :connect, @reconnect_ms)
    {:noreply, %{state | sock: nil}}
  end

  @impl true
  def handle_cast({:send, map}, state) do
    send_frame(state.sock, map)
    {:noreply, state}
  end

  @impl true
  def handle_call(:connected?, _from, state), do: {:reply, state.sock != nil, state}

  def handle_call({:eval_js, webview, code}, from, state) do
    id = state.next_id

    case send_frame(state.sock, %{op: "eval_js", id: id, webview: webview, code: code}) do
      :ok ->
        {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}

      :error ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:eval_site_js, app, code}, from, state) do
    id = state.next_id

    case send_frame(state.sock, %{op: "site_eval", app: app, id: id, code: code}) do
      :ok -> {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}
      :error -> {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:get_cookies, url}, from, state) do
    id = state.next_id

    case send_frame(state.sock, %{op: "get_cookies", id: id, url: url}) do
      :ok ->
        {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}

      :error ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  defp send_frame(nil, _map), do: :error

  defp send_frame(sock, map) do
    case :gen_tcp.send(sock, JSON.encode!(map)) do
      :ok -> :ok
      {:error, _} -> :error
    end
  end

  defp broadcast(event) do
    Registry.dispatch(BowserBrain.Events, :browser_event, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:browser_event, event})
    end)
  end

  defp js_reply(%{"ok" => true, "value" => value}), do: {:ok, value}
  defp js_reply(%{"value" => value}), do: {:error, value}
end
