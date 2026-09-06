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

  def socket_path, do: Path.join(BowserBrain.Paths.home(), "agent.sock")

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
        Logger.info("agent_port: listening at #{path}")
        {:noreply, start_acceptor(%{state | listener: listener})}

      {:error, reason} ->
        Logger.error("agent_port: listen failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # The acceptor died — after two hot-reloads of this file the code purge
  # killed it silently and every agent call then timed out with no clue why
  # (bowser-browser-y7g). Start another on the listener this server owns.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.get(state, :acceptor) do
      {_pid, ^ref} ->
        Logger.warning("agent_port: acceptor died (#{inspect(reason)}) — restarting")
        {:noreply, start_acceptor(Map.put(state, :acceptor, nil))}

      _ ->
        {:noreply, state}
    end
  end

  # Idempotent kick: start an acceptor only if none is alive.
  def handle_info(:ensure_acceptor, state) do
    alive? =
      case Map.get(state, :acceptor) do
        {pid, _ref} -> Process.alive?(pid)
        _ -> false
      end

    {:noreply, if(alive?, do: state, else: start_acceptor(state))}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp start_acceptor(%{listener: listener} = state) when listener != nil do
    {:ok, pid} = Task.start(fn -> __MODULE__.accept_loop(listener) end)
    Map.put(state, :acceptor, {pid, Process.monitor(pid)})
  end

  defp start_acceptor(state), do: state

  @doc false
  # External self-call on every connection: the loop always re-enters the
  # CURRENT module version, so a hot-reload never leaves it stranded on code
  # the next reload purges (which kills the process).
  def accept_loop(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, sock} ->
        # External call here too: the connection already being awaited when
        # this file hot-reloads must be served by CURRENT code, not by a
        # closure the old version created (that made exactly one request
        # after every reload answer "unknown tool").
        Task.start(fn -> __MODULE__.serve(sock) end)
        __MODULE__.accept_loop(listener)

      {:error, _closed} ->
        :ok
    end
  end

  @doc false
  def serve(sock) do
    case :gen_tcp.recv(sock, 0, 120_000) do
      {:ok, line} ->
        reply =
          case JSON.decode(line) do
            {:ok, request} -> safe_dispatch(request)
            {:error, _} -> %{ok: false, error: "request is not JSON"}
          end

        :gen_tcp.send(sock, [JSON.encode!(reply), "\n"])
        serve(sock)

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end

  # A tool that raises (an undefined module mid-hot-reload, a bad arg) must
  # still answer — a dead serve task left the client hanging until its own
  # timeout with no clue why (bowser-browser-y7g).
  defp safe_dispatch(request) do
    dispatch(request)
  rescue
    error -> %{ok: false, error: "tool crashed: " <> Exception.message(error)}
  end

  @doc "Tool dispatch. Public for tests; every arm returns a JSON-able map."
  def dispatch(%{"run" => run} = request) when is_binary(run) and run != "" do
    BowserBrain.ModWorkshop.tool(run, request["tool"], request["args"] || %{})
  end

  def dispatch(%{"tool" => tool, "args" => %{"site_app" => id} = args}) do
    BowserBrain.AppMods.dispatch(tool, args, id)
  end

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

  # What already exists, so an agent MODIFIES a mod instead of guessing or
  # duplicating it (bowser-browser-y7g).
  def dispatch(%{"tool" => "list_mods"}) do
    %{ok: true, mods: BowserBrain.ModCatalog.catalog()}
  end

  def dispatch(%{"tool" => "read_mod"} = request) do
    path = request |> Map.get("args", %{}) |> Map.get("path", "")

    case BowserBrain.ModCatalog.read(path) do
      {:ok, content} -> %{ok: true, path: path, content: content}
      {:error, :enoent} -> %{ok: false, error: "no such mod or payload: #{path} (see list_mods)"}
      {:error, reason} -> %{ok: false, error: "refused #{path}: #{inspect(reason)}"}
    end
  end

  # A mod's durable Store: read to check what it remembered, write to SEED
  # state (an old timestamp) so time-based behavior is verifiable now.
  def dispatch(%{"tool" => "store_get"} = request) do
    args = Map.get(request, "args", %{})
    mod = Map.get(args, "mod", "")
    key = Map.get(args, "key")

    cond do
      mod == "" -> %{ok: false, error: "mod (the defmodule name) is required"}
      key in [nil, ""] -> %{ok: true, mod: mod, all: BowserBrain.Store.all(mod)}
      true -> %{ok: true, mod: mod, key: key, value: BowserBrain.Store.get(mod, key)}
    end
  end

  def dispatch(%{"tool" => "store_put"} = request) do
    args = Map.get(request, "args", %{})
    mod = Map.get(args, "mod", "")
    key = Map.get(args, "key", "")

    cond do
      mod == "" or key == "" ->
        %{ok: false, error: "mod and key are required"}

      true ->
        case BowserBrain.Store.put(mod, key, Map.get(args, "value")) do
          :ok ->
            # The mod did not see this write: tell it, so a panel rendered
            # from the Store does not sit stale on a seeded/cleaned state
            # (the Follow Flywheel showed an 08:49 fixture at 10:36).
            notify_store_changed(mod, key)
            %{ok: true, mod: mod, key: key, notified: "store_changed"}

          {:error, reason} ->
            %{ok: false, error: "not JSON-shaped: #{reason}"}
        end
    end
  end

  def dispatch(%{"tool" => other}), do: %{ok: false, error: "unknown tool: #{other}"}
  def dispatch(_), do: %{ok: false, error: "missing tool field"}

  defp notify_store_changed(mod, key) do
    case Registry.lookup(BowserBrain.ModRegistry, Module.concat([mod])) do
      [{pid, _}] ->
        send(pid, {:browser_event, %{"event" => "store_changed", "mod" => mod, "key" => key}})

      _ ->
        :ok
    end
  end

  defp safe_eval(webview, js) do
    Bridge.eval_js(webview, js, 10_000)
  catch
    :exit, reason -> {:error, reason}
  end
end
