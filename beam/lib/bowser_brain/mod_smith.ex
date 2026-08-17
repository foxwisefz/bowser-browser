defmodule BowserBrain.ModSmith do
  @moduledoc """
  The omnibox LLM (bowser-browser-2hc): type `:do make this dark mode from
  now on` and ModSmith gathers page context, asks Claude (headless CLI),
  validates the returned envelope, and installs the files — site payloads
  under ~/.bowser/sites/<host>/ (applied by SiteMods, forever) or full mods
  under ~/.bowser/mods/ (hot-loaded by the Loader).

  The mod API is the DSL; the envelope is the contract:
  {"tier":"payload"|"mod","summary":"...","files":[{"path":"...","content":"..."}],"notes":"..."}
  """
  use GenServer
  require Logger

  import BowserBrain.View
  alias BowserBrain.{Page, SiteMods, Surface}

  @timeout_ms 180_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
    {:ok, %{active: 0, urls: %{}, busy: nil}}
  end

  @impl true
  def handle_info({:browser_event, %{"event" => "hello"}}, state) do
    BowserBrain.Chrome.register_command("do", "ModSmith")
    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "tab_activated", "webview" => wv}}, state) do
    {:noreply, %{state | active: wv}}
  end

  def handle_info({:browser_event, %{"event" => "url_changed", "webview" => wv, "url" => url}}, state) do
    {:noreply, %{state | urls: Map.put(state.urls, wv, url)}}
  end

  def handle_info({:browser_event, %{"event" => "omnibar_command", "text" => "do " <> request}}, state) do
    request = String.trim(request)

    cond do
      state.busy != nil ->
        status(["Busy with:", state.busy], :caption)
        {:noreply, state}

      request == "" ->
        {:noreply, state}

      true ->
        {:noreply, start_request(request, state)}
    end
  end

  def handle_info({:smith_done, request, result}, state) do
    case result do
      {:ok, summary, installed} ->
        Logger.info("modsmith: #{summary} — installed #{Enum.join(installed, ", ")}")
        status(["Done: #{summary}"] ++ installed, :caption)

      {:error, reason} ->
        Logger.error("modsmith: #{request} failed: #{reason}")
        status(["Failed:", reason], :caption)
    end

    {:noreply, %{state | busy: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---------------------------------------------------------------------

  defp start_request(request, state) do
    url = state.urls[state.active] || state.urls |> Map.values() |> List.first() || ""
    host = URI.parse(url).host || "unknown"
    digest = page_digest(state.active)
    existing = SiteMods.payloads_for(host)

    status(["Working on:", request], :caption)
    prompt = build_prompt(request, url, host, digest, existing)
    parent = self()

    Task.start(fn ->
      result = run_claude(prompt)
      send(parent, {:smith_done, request, result && install(result, host)})
    end)

    %{state | busy: request}
  end

  defp page_digest(webview) do
    probe = """
    JSON.stringify({
      host: location.hostname, path: location.pathname, title: document.title,
      bg: getComputedStyle(document.body).backgroundColor,
      fg: getComputedStyle(document.body).color,
      colorScheme: getComputedStyle(document.documentElement).colorScheme,
      darkMeta: !!document.querySelector('meta[name="color-scheme"]'),
      mainCandidates: ["main","article","[role=main]","#content",".content"]
        .filter(function (s) { return document.querySelector(s); })
    })
    """

    case Page.eval(probe, webview: webview) do
      {:ok, json} when is_binary(json) -> json
      _ -> "{}"
    end
  end

  defp build_prompt(request, url, host, digest, existing) do
    existing_block =
      case existing do
        [] ->
          "None."

        files ->
          Enum.map_join(files, "\n", fn {name, content} ->
            "--- sites/#{host}/#{name} ---\n#{String.slice(content, 0, 2000)}"
          end)
      end

    """
    You are ModSmith, the mod generator inside Bowser, a personal moddable browser.
    Produce browser customizations for the OWNER's request. Reply with ONLY a JSON
    envelope, no prose, no markdown fences:

    {"tier":"payload"|"mod","summary":"<one line>","files":[{"path":"...","content":"..."}],"notes":"<caveats>"}

    TIERS:
    - "payload" (STRONGLY PREFERRED): files under sites/#{host}/ named *.css or *.js.
      They are auto-injected on every page of #{host}, persistently. CSS over JS
      when possible. To change an existing payload, return the same path with new
      content. To remove behavior, return the file with empty content.
    - "mod" (only when state/events/chrome are required): one file under mods/*.ex,
      an Elixir module using the mod API below.

    HARD RULES: paths only under sites/ or mods/; never read or touch password,
    credit-card, or one-time-code fields; keep CSS resilient (avoid brittle
    generated class names; prefer semantic/aria/structural selectors).

    MOD API (for tier "mod"):
    defmodule MyMod do use BowserBrain.Mod
      def init_mod(_opts), do: %{}                # state
      def handle_event(event, state), do: state   # events are string-keyed maps
    end
    Events: "url_changed"(url,webview) "title_changed"(title) "load_status"(status 0|2)
    "chrome_click"(id) "omnibar_command"(text) "page"(payload via window.bowser.emit in
    injected JS) "tab_opened"(webview,opener) "tab_activated"(webview) "hello" "mod_reloaded".
    APIs: BowserBrain.Browser.navigate(url); BowserBrain.Page.eval(js, webview: 0) ->
    {:ok,val}; Page.set_styles([css]); Page.set_scripts([js]) (engine-injected, owner-keyed);
    BowserBrain.Chrome.add_button(id, title, symbol: "sfsymbol");
    BowserBrain.Surface.show(id, view, title: "T", anchor: :right_of_main) with
    import BowserBrain.View: vstack/hstack(list, opts), text(v, style: :title|:caption),
    button(label, event:, payload:, active:, symbol:, indent:), slider(event, min:, max:,
    value:, label:), textfield(event, placeholder:), divider(). Surface events arrive as
    %{"event"=>"surface","surface"=>id,"id"=>ev,"value"=>v}.

    CONTEXT:
    Current URL: #{url}
    Page digest: #{digest}
    Existing payloads for #{host}:
    #{existing_block}

    OWNER REQUEST: #{request}
    """
  end

  defp run_claude(prompt) do
    case System.find_executable("claude") do
      nil ->
        {:error, "claude CLI not found on PATH"}

      claude ->
        env = claude_env()
        args = ["-p", prompt] ++ model_args()

        task =
          Task.async(fn ->
            # sh wrapper: claude waits 3s on the port's dangling stdin
            # without an explicit < /dev/null.
            System.cmd(
              "/bin/sh",
              ["-c", ~s(exec "$0" "$@" < /dev/null), claude | args],
              stderr_to_stdout: true,
              env: env
            )
          end)

        case Task.yield(task, @timeout_ms) || Task.shutdown(task) do
          {:ok, {output, 0}} -> {:output, output}
          {:ok, {output, code}} -> {:error, "claude exited #{code}: #{String.slice(output, 0, 300)}"}
          nil -> {:error, "claude timed out"}
        end
    end
  end

  # Route through a custom endpoint (e.g. DodoRouter) when configured:
  #   :set dodorouter_endpoint https://...
  #   :set dodorouter_api_key sk-...
  defp claude_env do
    [
      {"ANTHROPIC_BASE_URL", BowserBrain.Settings.get("dodorouter_endpoint")},
      {"ANTHROPIC_API_KEY", BowserBrain.Settings.get("dodorouter_api_key")}
    ]
    |> Enum.filter(fn {_name, value} -> is_binary(value) and value != "" end)
  end

  # Routers serve their own model ids; the CLI's default may not exist there.
  #   :set modsmith_model <id-your-router-serves>
  defp model_args do
    case BowserBrain.Settings.get("modsmith_model") do
      model when is_binary(model) and model != "" -> ["--model", model]
      _ -> []
    end
  end

  defp install({:error, _} = error, _host), do: error

  defp install({:output, output}, _host) do
    with {:ok, envelope} <- extract_json(output),
         files when files != [] <- Map.get(envelope, "files", []),
         :ok <- validate(files) do
      installed = Enum.map(files, &write_file/1)
      {:ok, Map.get(envelope, "summary", "done"), installed}
    else
      [] -> {:error, "envelope had no files"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_json(output) do
    with start when start != nil <- :binary.match(output, "{") |> elem_or_nil(0),
         finish when finish != nil <- last_brace(output),
         {:ok, decoded} <- JSON.decode(binary_part(output, start, finish - start + 1)) do
      {:ok, decoded}
    else
      _ -> {:error, "no parseable JSON envelope in reply: #{String.slice(output, 0, 200)}"}
    end
  end

  defp elem_or_nil(:nomatch, _), do: nil
  defp elem_or_nil(tuple, index), do: elem(tuple, index)

  defp last_brace(binary) do
    case :binary.matches(binary, "}") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp validate(files) do
    Enum.reduce_while(files, :ok, fn %{"path" => path, "content" => content}, :ok ->
      cond do
        String.contains?(path, "..") ->
          {:halt, {:error, "path traversal refused: #{path}"}}

        not (String.starts_with?(path, "sites/") or String.starts_with?(path, "mods/")) ->
          {:halt, {:error, "path outside sites//mods/: #{path}"}}

        byte_size(content) > 200_000 ->
          {:halt, {:error, "file too large: #{path}"}}

        String.ends_with?(path, ".ex") ->
          case Code.string_to_quoted(content) do
            {:ok, _} -> {:cont, :ok}
            {:error, {meta, message, token}} ->
              {:halt, {:error, "mod syntax error #{inspect(meta)}: #{inspect(message)} #{inspect(token)}"}}
          end

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp write_file(%{"path" => path, "content" => content}) do
    target = Path.join(Path.join(System.user_home!(), ".bowser"), path)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, content)
    path
  end

  defp status(lines, style) do
    Surface.show(
      :modsmith,
      vstack([text("ModSmith", style: :title)] ++ Enum.map(lines, &text(&1, style: style))),
      title: "ModSmith",
      anchor: :right_of_main,
      width: 260
    )
  end
end
