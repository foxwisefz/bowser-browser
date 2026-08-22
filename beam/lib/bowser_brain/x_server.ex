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

  def route(path) do
    {clean, params} = split_params(path)
    want = params["want"]
    view = params["view"]

    case clean do
      "/x/home" -> timeline("home", "Home", want, view)
      "/x/search/" <> q -> timeline("search:" <> URI.decode(q), "Search: #{URI.decode(q)}", want, view)
      "/x/@" <> handle -> timeline("@" <> handle, "@" <> handle, want, view)
      "/x/" <> route -> timeline(route, route, want, view)
      _ -> {404, ~s({"error":"not found"})}
    end
  end

  # `?want=N` controls scroll depth (infinite scroll); `?view=gallery`
  # swaps the screen declaration — same data, a different native app.
  @doc false
  def split_params(path) do
    case String.split(path, "?", parts: 2) do
      [clean, query] ->
        q = URI.decode_query(query)

        want =
          case Integer.parse(Map.get(q, "want", "15")) do
            {n, _} when n > 0 and n <= 1000 -> n
            _ -> 15
          end

        {clean, %{"want" => want, "view" => Map.get(q, "view")}}

      [clean] ->
        {clean, %{"want" => 15, "view" => nil}}
    end
  end

  defp timeline(route, title, want, view) do
    case XFeed.fetch(route, want, @fetch_timeout) do
      {:ok, tweets} ->
        {screen, tweets} = present(view, title, tweets)
        payload = %{"screen" => screen, "data" => %{"tweets" => tweets}}
        {200, JSON.encode!(payload)}

      {:error, reason} ->
        {502, JSON.encode!(%{"error" => "feed unavailable", "reason" => inspect(reason)})}
    end
  end

  # Pick the screen + shape the data for the requested view.
  defp present("gallery", _title, tweets) do
    media =
      tweets
      |> Enum.filter(fn t -> t.photos != [] end)
      |> Enum.sort_by(&engagement/1, :desc)

    {SDUI.x_gallery("Big"), media}
  end

  defp present(_default, title, tweets), do: {SDUI.x_timeline(title), tweets}

  # Parse "19K"/"1.2M" into a sortable number.
  defp engagement(t) do
    raw = t.metrics[:likes] || "0"

    {num, mult} =
      case Regex.run(~r/^([\d.,]+)\s*([KMB]?)/i, raw) do
        [_, n, "K"] -> {n, 1_000}
        [_, n, "M"] -> {n, 1_000_000}
        [_, n, "B"] -> {n, 1_000_000_000}
        [_, n, _] -> {n, 1}
        _ -> {"0", 1}
      end

    case Float.parse(String.replace(num, ",", "")) do
      {f, _} -> f * mult
      _ -> 0
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
