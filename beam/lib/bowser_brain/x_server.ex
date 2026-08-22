defmodule BowserBrain.XServer do
  @moduledoc """
  The phone's data endpoint (ADR 0011, bowser-browser-3fo): a tiny HTTP/1.1
  server (hand-rolled on :gen_tcp — inets is unusable in this OTP) that
  serves SDUI declarations plus live data to the iOS renderer.

      GET /x/home          -> {"screen": <declaration>, "data": {"tweets": [...]}}
      GET /x/@handle       -> a profile's timeline
      GET /x/search/query  -> search results
      GET /health          -> "ok"

  The screen comes from BowserBrain.SDUI (the editable mod), the data from
  BowserBrain.XFeed (the live-session harness). Localhost for the simulator;
  bind to 0.0.0.0 so a device on the LAN can reach it too.
  """
  use GenServer
  require Logger

  alias BowserBrain.{SDUI, XFeed}

  @port 4808
  @fetch_timeout 25_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(opts, :name, __MODULE__))

  def port, do: @port

  @impl true
  def init(nil) do
    if Application.get_env(:bowser_brain, :connect_bridge, true) do
      send(self(), :listen)
    end

    {:ok, %{listener: nil}}
  end

  @impl true
  def handle_info(:listen, state) do
    case :gen_tcp.listen(@port, [:binary, packet: :http_bin, active: false, reuseaddr: true, ip: {0, 0, 0, 0}]) do
      {:ok, listener} ->
        server = self()
        Task.start(fn -> accept_loop(listener, server) end)
        Logger.info("xserver: listening on http://0.0.0.0:#{@port}")
        {:noreply, %{state | listener: listener}}

      {:error, reason} ->
        Logger.error("xserver: listen failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp accept_loop(listener, server) do
    case :gen_tcp.accept(listener) do
      {:ok, sock} ->
        Task.start(fn -> serve(sock) end)
        accept_loop(listener, server)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock) do
    case read_request(sock) do
      {:ok, path} ->
        {status, body} = route(path)
        :gen_tcp.send(sock, response(status, body))

      :error ->
        :gen_tcp.send(sock, response(400, ~s({"error":"bad request"})))
    end

    :gen_tcp.close(sock)
  end

  # Read just the request line + drain headers (packet: :http_bin parses).
  defp read_request(sock) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, {:http_request, _method, {:abs_path, path}, _ver}} ->
        drain_headers(sock)
        {:ok, to_string(path)}

      _ ->
        :error
    end
  end

  defp drain_headers(sock) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, :http_eoh} -> :ok
      {:ok, {:http_header, _, _, _, _}} -> drain_headers(sock)
      _ -> :ok
    end
  end

  @doc false
  # Path -> {status, json}. Public for tests (route matching is pure aside
  # from the XFeed calls, which the test stubs by hitting /health).
  def route("/health"), do: {200, "ok"}

  def route("/x/home"), do: timeline("home", "Home")

  def route("/x/search/" <> query) do
    timeline("search:" <> URI.decode(query), "Search: #{URI.decode(query)}")
  end

  def route("/x/@" <> handle) do
    timeline("@" <> handle, "@" <> handle)
  end

  def route("/x/" <> route) do
    timeline(route, route)
  end

  def route(_), do: {404, ~s({"error":"not found"})}

  defp timeline(route, title) do
    case XFeed.fetch(route, @fetch_timeout) do
      {:ok, tweets} ->
        payload = %{"screen" => SDUI.x_timeline(title), "data" => %{"tweets" => tweets}}
        {200, JSON.encode!(payload)}

      {:error, reason} ->
        {502, JSON.encode!(%{"error" => "feed unavailable", "reason" => inspect(reason)})}
    end
  end

  defp response(status, body) when is_binary(body) do
    reason =
      case status do
        200 -> "OK"
        400 -> "Bad Request"
        404 -> "Not Found"
        502 -> "Bad Gateway"
        _ -> "Error"
      end

    ct = if String.starts_with?(body, "{") or String.starts_with?(body, "["), do: "application/json", else: "text/plain"

    "HTTP/1.1 #{status} #{reason}\r\n" <>
      "Content-Type: #{ct}\r\n" <>
      "Access-Control-Allow-Origin: *\r\n" <>
      "Content-Length: #{byte_size(body)}\r\n" <>
      "Connection: close\r\n\r\n" <> body
  end
end
