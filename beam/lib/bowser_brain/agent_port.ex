defmodule BowserBrain.AgentPort do
  @moduledoc """
  Tool socket for mod-building agents (bowser-browser-4uw): a line-JSON
  server at ~/.bowser/agent.sock. ModSmith hands the claude CLI an MCP
  bridge (bin/bowser-mcp-bridge) that relays tool calls here, so the model
  can INSPECT the live page, install a draft payload, and VERIFY the result
  before it finalizes — a dialog with the browser instead of a blind
  one-shot generation.

  Request:  {"tool": "page_eval", "args": {"js": "...", "webview": 0}}\\n
  Response: {"ok": true, ...} | {"ok": false, "error": "..."}\\n
  """
  use GenServer
  require Logger

  alias BowserBrain.{Bridge, SiteMods}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def socket_path, do: Path.join(System.user_home!(), ".bowser/agent.sock")

  @impl true
  def init(nil) do
    # Same hermetic fence as the Bridge: tests never open owner sockets.
    if Application.get_env(:bowser_brain, :connect_bridge, true) do
      send(self(), :listen)
    end

    {:ok, %{listener: nil}}
  end

  @impl true
  def handle_info(:listen, state) do
    path = socket_path()
    File.rm(path)

    case :gen_tcp.listen(0, [
           :binary,
           ifaddr: {:local, String.to_charlist(path)},
           packet: :line,
           active: false,
           reuseaddr: true
         ]) do
      {:ok, listener} ->
        server = self()
        Task.start(fn -> accept_loop(listener, server) end)
        Logger.info("agent_port: listening at #{path}")
        {:noreply, %{state | listener: listener}}

      {:error, reason} ->
        Logger.error("agent_port: listen failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp accept_loop(listener, server) do
    case :gen_tcp.accept(listener) do
      {:ok, sock} ->
        Task.start(fn -> serve(sock) end)
        accept_loop(listener, server)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(sock) do
    case :gen_tcp.recv(sock, 0, 120_000) do
      {:ok, line} ->
        reply =
          case JSON.decode(line) do
            {:ok, request} -> dispatch(request)
            {:error, _} -> %{ok: false, error: "request is not JSON"}
          end

        :gen_tcp.send(sock, [JSON.encode!(reply), "\n"])
        serve(sock)

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end

  @doc "Tool dispatch. Public for tests; every arm returns a JSON-able map."
  def dispatch(%{"tool" => "list_tabs"}) do
    session = :sys.get_state(BowserBrain.Session)
    tabs = session.tabs |> Enum.sort() |> Enum.map(fn {wv, url} -> %{webview: wv, url: url} end)
    %{ok: true, tabs: tabs, active: session.active}
  end

  def dispatch(%{"tool" => "page_eval"} = request) do
    args = Map.get(request, "args", %{})
    js = Map.get(args, "js", "")
    webview = Map.get(args, "webview", 0)

    case safe_eval(webview, js) do
      {:ok, value} -> %{ok: true, value: value}
      {:error, reason} -> %{ok: false, error: "eval failed: #{inspect(reason)}"}
    end
  end

  def dispatch(%{"tool" => "page_html"} = request) do
    args = Map.get(request, "args", %{})
    selector = Map.get(args, "selector", "body")
    webview = Map.get(args, "webview", 0)

    js = """
    (function () {
      var el = document.querySelector(#{JSON.encode!(selector)});
      if (!el) return "NO MATCH for selector";
      var html = el.outerHTML || "";
      return html.length > 20000 ? html.slice(0, 20000) + "…[truncated]" : html;
    })()
    """

    case safe_eval(webview, js) do
      {:ok, value} -> %{ok: true, html: value}
      {:error, reason} -> %{ok: false, error: "eval failed: #{inspect(reason)}"}
    end
  end

  def dispatch(%{"tool" => "put_payload"} = request) do
    args = Map.get(request, "args", %{})
    host = Map.get(args, "host", "")
    name = Map.get(args, "name", "")
    content = Map.get(args, "content", "")

    cond do
      host == "" or String.contains?(host, "/") or String.contains?(host, "..") ->
        %{ok: false, error: "host must be a bare hostname"}

      Path.extname(name) not in [".css", ".js"] ->
        %{ok: false, error: "name must end in .css or .js"}

      byte_size(content) > 200_000 ->
        %{ok: false, error: "content too large"}

      true ->
        SiteMods.put(host, name, content)
        %{ok: true, installed: "sites/#{host}/#{name}", applies: "within ~1s, on page reload"}
    end
  end

  def dispatch(%{"tool" => other}), do: %{ok: false, error: "unknown tool: #{other}"}
  def dispatch(_), do: %{ok: false, error: "missing tool field"}

  defp safe_eval(webview, js) do
    Bridge.eval_js(webview, js, 10_000)
  catch
    :exit, reason -> {:error, reason}
  end
end
