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

  # 180s proved too short: a rate-limited router makes the CLI retry 502s
  # for minutes, and the whole request died as "claude timed out"
  # (bowser-browser-3l4). Tune live with `:set modsmith_timeout_ms`.
  @default_timeout_ms 600_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
    # sessions: numbered refinement history, newest first, persisted to disk —
    # the claude CLI keeps its transcripts on disk, so --resume stays valid
    # across brain AND engine restarts (bowser-browser-lv4).
    {:ok, %{active: 0, urls: %{}, busy: nil, sessions: load_sessions(), last_status: "Ready."}}
  end

  @impl true
  def handle_info({:browser_event, %{"event" => "hello"}}, state) do
    BowserBrain.Chrome.register_command("do", "ModSmith — new request")
    BowserBrain.Chrome.register_command("do+", "ModSmith — refine (do+N picks a session)")
    declare_settings()
    # IRON RULE: the panel is shell state and died with the engine — re-show.
    render(state)
    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "tab_activated", "webview" => wv}}, state) do
    {:noreply, %{state | active: wv}}
  end

  def handle_info({:browser_event, %{"event" => "url_changed", "webview" => wv, "url" => url}}, state) do
    {:noreply, %{state | urls: Map.put(state.urls, wv, url)}}
  end

  def handle_info({:browser_event, %{"event" => "omnibar_command", "text" => "do+" <> rest}}, state) do
    {target, request} = parse_followup(rest)

    cond do
      state.busy != nil ->
        render(state, "Busy with: #{state.busy}")
        {:noreply, state}

      state.sessions == [] ->
        render(state, "No sessions yet — :do to start one")
        {:noreply, state}

      true ->
        case fetch_session(state.sessions, target) do
          nil ->
            render(state, "No session ##{target} — panel lists what exists")
            {:noreply, state}

          _session when request == "" and is_integer(target) ->
            # `:do+N` alone: peek at what that number refers to.
            {n, s} = {target, Enum.at(state.sessions, target - 1)}
            render(state, "##{n}: #{s.request} → #{s.summary}")
            {:noreply, state}

          _session when request == "" ->
            {:noreply, state}

          session ->
            {:noreply, start_request(request, state, resume: session.id)}
        end
    end
  end

  def handle_info({:browser_event, %{"event" => "omnibar_command", "text" => "do " <> request}}, state) do
    request = String.trim(request)

    cond do
      state.busy != nil ->
        render(state, "Busy with: #{state.busy}")
        {:noreply, state}

      request == "" ->
        {:noreply, state}

      true ->
        {:noreply, start_request(request, state, [])}
    end
  end

  def handle_info({:smith_done, request, session, resumed, host, result}, state) do
    case result do
      {:ok, summary, installed} ->
        Logger.info("modsmith: #{summary} — installed #{Enum.join(installed, ", ")}")

        sessions =
          if session do
            # A --resume produces a NEW session id continuing the old
            # lineage: the refined entry is replaced, not duplicated.
            remember_session(state.sessions, %{
              id: session,
              request: request,
              summary: summary,
              host: host,
              at: System.system_time(:millisecond),
              refined: resumed
            })
          else
            state.sessions
          end

        persist_sessions(sessions)
        state = %{state | busy: nil, sessions: sessions, last_status: "Done: #{summary}"}
        render(state)
        {:noreply, state}

      {:handoff, summary} ->
        # ModSmith deliberately declined a too-big task (SIZE RULE). Not a
        # failure — a handoff the owner can hand to the resident agent.
        Logger.info("modsmith: handoff — #{summary}")
        state = %{state | busy: nil, last_status: "↗ #{String.slice(summary, 0, 160)}"}
        render(state)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("modsmith: #{request} failed: #{reason}")
        state = %{state | busy: nil, last_status: "Failed: #{String.slice(reason, 0, 120)}"}
        render(state)
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---------------------------------------------------------------------

  defp start_request(request, state, opts) do
    resume = Keyword.get(opts, :resume)
    Logger.info("modsmith: request received#{if resume, do: " (follow-up)"}: #{request}")
    url = state.urls[state.active] || state.urls |> Map.values() |> List.first() || ""
    host = URI.parse(url).host || "unknown"

    prompt =
      if resume do
        # The session already holds the contract, cheatsheet, and its own
        # prior envelope — just refresh the volatile context.
        """
        FOLLOW-UP on your previous work (same envelope contract — reply with
        ONLY the JSON envelope; return full updated file contents for any
        file you change).
        Current URL: #{url}
        Settings now: #{BowserBrain.Settings.summary()}
        REFINEMENT REQUEST: #{request}
        """
      else
        build_prompt(request, url, host, page_digest(state.active), SiteMods.payloads_for(host))
      end

    render(%{state | busy: request}, "Working on: #{request}")
    parent = self()

    Task.start(fn ->
      {session, result} = run_claude(prompt, resume)
      send(parent, {:smith_done, request, session, resume, host, result && install(result, host)})
    end)

    %{state | busy: request}
  end

  @doc """
  Parse the text after `:do+`. A digit GLUED to the plus selects a session
  (`do+2 tighter cards` → `{2, "tighter cards"}`); with a space it's just a
  request that happens to start with a number (`do+ 2x faster` → latest).
  `do+N` alone peeks. Public for tests.
  """
  def parse_followup(rest) do
    case Integer.parse(rest) do
      {n, remainder} when n > 0 and (remainder == "" or binary_part(remainder, 0, 1) == " ") ->
        {n, String.trim(remainder)}

      _ ->
        {:latest, String.trim(rest)}
    end
  end

  @doc """
  Add a finished run to the history: replaces its own id and the id it
  refined (lineage), newest first, capped at 8. Public for tests.
  """
  def remember_session(sessions, entry) do
    lineage = Map.get(entry, :refined)
    entry = Map.delete(entry, :refined)

    sessions
    |> Enum.reject(fn s -> s.id == entry.id or (lineage != nil and s.id == lineage) end)
    |> then(&[entry | &1])
    |> Enum.take(8)
  end

  defp fetch_session(sessions, :latest), do: List.first(sessions)
  defp fetch_session(sessions, n) when is_integer(n), do: Enum.at(sessions, n - 1)

  defp sessions_path do
    Application.get_env(
      :bowser_brain,
      :modsmith_sessions_path,
      Path.join(System.user_home!(), ".bowser/modsmith-sessions.json")
    )
  end

  defp load_sessions do
    with {:ok, raw} <- File.read(sessions_path()),
         {:ok, list} when is_list(list) <- JSON.decode(raw) do
      for %{"id" => id} = s <- list do
        %{
          id: id,
          request: Map.get(s, "request", "?"),
          summary: Map.get(s, "summary", "?"),
          host: Map.get(s, "host", "?"),
          at: Map.get(s, "at", 0)
        }
      end
    else
      _ -> []
    end
  end

  defp persist_sessions(sessions), do: File.write(sessions_path(), JSON.encode!(sessions))

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

    # Best-effort: a slow/hung page must not crash ModSmith (a GenServer.call
    # timeout exits the caller — this is how requests were silently lost).
    result =
      try do
        Page.eval(probe, webview: webview)
      catch
        :exit, _ -> {:error, :timeout}
      end

    case result do
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
    Produce browser customizations for the OWNER's request.

    YOU HAVE LIVE TOOLS into the running browser — use them instead of guessing:
    list_tabs (which webview is which), page_html (ground-truth DOM for a selector),
    page_eval (run JS, check computed styles, probe selectors), put_payload
    (install a draft payload NOW — applies within ~1s after you reload via
    page_eval "location.reload()"). WORKFLOW: inspect the real DOM first; draft;
    put_payload; reload; page_eval to VERIFY the change actually took (selector
    matched, style applied); iterate until it does. Do not finish while unverified.

    When done, reply with ONLY a JSON envelope, no prose, no markdown fences:

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

    SIZE RULE: you are the small fast path. If the request needs multiple
    subsystems (audio/media pipelines, external API integrations beyond one
    fetch, new brain-side services, anything you cannot VERIFY with your
    tools), do NOT attempt it — reply IMMEDIATELY with an envelope of zero
    files and a summary starting "NEEDS THE RESIDENT AGENT:" plus one line
    on why. A fast honest handoff beats a ten-minute timeout.

    SCOPE RULE: a request about a specific page/site must be limited to that
    site by default. Payloads are auto host-scoped. A tier-"mod" for
    page-specific behavior MUST declare its host:
      use BowserBrain.Mod, host: "#{host}"
    — events from tabs on other sites then never reach handle_event
    (subdomains included). Omit host: ONLY for genuinely browser-wide mods
    (tab docks, global chrome).

    MOD API (for tier "mod"):
    defmodule MyMod do use BowserBrain.Mod          # add host: "site" per SCOPE RULE
      def init_mod(_opts), do: %{}                # state
      def handle_event(event, state), do: state   # events are string-keyed maps
    end
    Events: "url_changed"(url,webview) "title_changed"(title) "load_status"(status 0|2)
    "chrome_click"(id) "omnibar_command"(text) "page"(payload via window.bowser.emit in
    injected JS) "tab_opened"(webview,opener) "tab_activated"(webview) "hello" "mod_reloaded".
    APIs: BowserBrain.Browser.navigate(url); BowserBrain.Page.eval(js, webview: 0) ->
    {:ok,val}; Page.set_styles([css]); Page.set_scripts([js]) (engine-injected, owner-keyed);
    BowserBrain.Chrome.add_button(id, title, symbol: "sfsymbol");
    BowserBrain.Chrome.add_menu_item(id, title, key: "e"?) — item in the native View
    menu (key: optional single-char ⌘-equivalent); clicks arrive as "chrome_click"(id)
    exactly like buttons; Chrome.remove_menu_item(id). The View menu already has
    Reload ⌘R, Actual Size/Zoom In/Out ⌘0/⌘+/⌘-, Enter Full Screen — never duplicate those.
    BowserBrain.Surface.show(id, view, title: "T", anchor: :right_of_main) with
    import BowserBrain.View: vstack/hstack(list, opts), text(v, style: :title|:caption),
    button(label, event:, payload:, active:, symbol:, indent:), slider(event, min:, max:,
    value:, label:), textfield(event, placeholder:), divider(), particles(chars: ["♪"],
    rate: 3.0, active: bool). Surface events arrive as
    %{"event"=>"surface","surface"=>id,"id"=>ev,"value"=>v}.
    SETTINGS (for API keys etc.): in init_mod declare what you need —
    BowserBrain.Settings.declare("service_api_key", secret: true, about: "why/what for")
    — the owner fills it in the :settings panel; read with
    BowserBrain.Settings.get("service_api_key") (nil until set; degrade gracefully
    and surface a hint). Never hardcode credentials. Surface.show also takes
    kind: :toolbar_overlay — a click-through effects layer over the browser's real
    toolbar (pair with particles for chrome effects) — and kind: :edge (edge: :left|:right,
    peek: px, width: px, attach: :window|:screen — :screen = macOS-Dock style): an edge
    surface, mostly hidden, sliding into view on cursor proximity. Pair :edge with
    magnify_strip(items, size: px, magnify: SCALE MULTIPLIER like 2.0 (NOT pixels),
    event:) — items are [%{id:, path: (icon file) or symbol:, active:, title:}]; the
    shell natively handles dock-style proximity magnification, emitting select events
    (value = item id). EXACT hello shape: %{"event"=>"hello", "tabs"=>[%{"id"=>wv,
    "url"=>u|nil, "title"=>t?, "favicon"=>path?}], "active"=>wv? (TOP-LEVEL)}. Live
    favicon updates: "favicon_changed" {webview, path}. Focus/close tabs with
    BowserBrain.Surface.activate_tab(wv) / Surface.close_tab(wv).
    There is NO native tab bar: one window holds N in-memory webviews and tab UI
    is entirely mod-owned. Chrome.open_tab(url, activate: false) makes a tab;
    Surface.activate_tab(wv) is what puts it on screen.
    IRON RULE: ALL engine/shell-side state (buttons, registered commands, hidden tab
    bar, surfaces, injected scripts) dies when the engine restarts — re-assert ALL of
    it in your "hello" handler, not just in init_mod (init often runs before the
    bridge connects and casts are silently dropped). Pages can push to mods via
    window.bowser.emit(payload) in injected JS -> event "page" {payload}.

    CONTEXT:
    Current URL: #{url}
    Page digest: #{digest}
    Existing settings (REUSE these key names where relevant instead of
    inventing new ones; declare + prompt for anything missing):
    #{BowserBrain.Settings.summary()}
    Existing payloads for #{host}:
    #{existing_block}

    OWNER REQUEST: #{request}
    """
  end

  defp run_claude(prompt, resume) do
    settings = BowserBrain.Settings.all()

    case {System.find_executable("claude"), auth_route(settings)} do
      {nil, _route} ->
        {nil, {:error, "claude CLI not found on PATH — install it, then sign in or set up a router in :settings"}}

      {_claude, {:missing, key}} ->
        {nil,
         {:error,
          "router half-configured: `:set #{key} <value>` to finish, " <>
            "or clear both dodorouter settings to use your claude CLI login"}}

      {claude, route} ->
        env = claude_env(settings)

        args =
          ["-p", prompt, "--output-format", "json"] ++
            mcp_args() ++
            model_args() ++
            if(resume, do: ["--resume", resume], else: [])

        Logger.info(
          "modsmith: exec claude <#{byte_size(prompt)}B prompt> " <>
            "#{Enum.join(model_args(), " ")}#{if resume, do: " --resume #{resume}"} " <>
            "| env: #{Enum.map_join(env, ",", &elem(&1, 0))}"
        )

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

        timeout = timeout_ms(BowserBrain.Settings.get("modsmith_timeout_ms"))

        case Task.yield(task, timeout) || Task.shutdown(task) do
          {:ok, {output, 0}} ->
            case JSON.decode(output) do
              {:ok, %{"result" => text} = envelope} ->
                {envelope["session_id"], {:output, text}}

              _ ->
                {nil, {:output, output}}
            end

          {:ok, {output, code}} ->
            {nil,
             {:error,
              "claude exited #{code}: #{String.slice(output, 0, 300)} | #{auth_hint(route)}"}}

          nil ->
            {nil, {:error, "claude timed out after #{div(timeout, 1000)}s"}}
        end
    end
  end

  @doc false
  # Owner-tunable request budget: raw `:set modsmith_timeout_ms` value in,
  # milliseconds out. Public for tests.
  def timeout_ms(setting) when is_binary(setting) do
    case Integer.parse(setting) do
      {ms, _} when ms > 0 -> ms
      _ -> @default_timeout_ms
    end
  end

  def timeout_ms(_unset), do: @default_timeout_ms

  # Surface every ModSmith knob in the :settings palette with its purpose,
  # so a fresh install can configure auth without reading source
  # (bowser-browser-bzy). Auth is either of:
  #   - nothing set: your own claude CLI login (`claude` once in a terminal)
  #   - both dodorouter_* keys: requests route through that endpoint
  defp declare_settings do
    alias BowserBrain.Settings

    Settings.declare("dodorouter_endpoint",
      about: ":do routing — optional router base URL; leave unset to use your claude CLI login"
    )

    Settings.declare("dodorouter_api_key",
      secret: true,
      about: ":do routing — router token (sent as CLAUDE_CODE_OAUTH_TOKEN); set with the endpoint"
    )

    Settings.declare("modsmith_model",
      about: ":do model id — routers serve their own ids; unset = CLI default"
    )

    Settings.declare("modsmith_timeout_ms",
      about: ":do request budget in ms (default #{@default_timeout_ms})"
    )
  end

  @doc """
  Which auth path :do will use, from the settings map. Two supported ways
  to run ModSmith (bowser-browser-bzy):

    * `:cli` — nothing configured; the claude CLI uses its own login
      (run `claude` once in a terminal to sign in).
    * `{:router, endpoint}` — both `dodorouter_endpoint` and
      `dodorouter_api_key` set; requests route through the endpoint.

  A half-set router pair is `{:missing, key}` — refused early with the key
  to fix, instead of a misleading CLI error. Public for tests.
  """
  def auth_route(settings) when is_map(settings) do
    endpoint = present(settings["dodorouter_endpoint"])
    key = present(settings["dodorouter_api_key"])

    case {endpoint, key} do
      {nil, nil} -> :cli
      {endpoint, key} when endpoint != nil and key != nil -> {:router, endpoint}
      {nil, _key} -> {:missing, "dodorouter_endpoint"}
      {_endpoint, nil} -> {:missing, "dodorouter_api_key"}
    end
  end

  @doc """
  Extra env for the claude CLI. Router mode rides Claude Code's own auth:
  the token goes out as CLAUDE_CODE_OAUTH_TOKEN. CLI mode adds nothing —
  the user's own login applies. Public for tests.
  """
  def claude_env(settings) do
    case auth_route(settings) do
      {:router, endpoint} ->
        [
          {"ANTHROPIC_BASE_URL", endpoint},
          {"CLAUDE_CODE_OAUTH_TOKEN", present(settings["dodorouter_api_key"])}
        ]

      _ ->
        []
    end
  end

  @doc "One-line setup guidance appended to auth-shaped failures. Public for tests."
  def auth_hint(:cli) do
    "ModSmith used your local claude CLI login — if you haven't signed in, " <>
      "run `claude` once in a terminal, or route via " <>
      "`:set dodorouter_endpoint <url>` + `:set dodorouter_api_key <token>`"
  end

  def auth_hint({:router, endpoint}) do
    "ModSmith routed via #{endpoint} — check the endpoint and dodorouter_api_key in :settings"
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_other), do: nil

  # The live-browser toolbox (bowser-browser-4uw): an MCP bridge relaying to
  # AgentPort at ~/.bowser/agent.sock, so the model can inspect the page,
  # install a draft, and verify — a dialog, not a blind one-shot.
  @mcp_tools "mcp__bowser__list_tabs,mcp__bowser__page_eval," <>
               "mcp__bowser__page_html,mcp__bowser__put_payload"

  defp mcp_args do
    config = Path.join(System.user_home!(), ".bowser/agent-mcp.json")

    File.write!(
      config,
      JSON.encode!(%{
        mcpServers: %{bowser: %{command: "python3", args: [BowserBrain.Paths.mcp_bridge()]}}
      })
    )

    ["--mcp-config", config, "--allowedTools", @mcp_tools]
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
    case extract_json(output) do
      {:ok, envelope} ->
        files = Map.get(envelope, "files", [])
        summary = Map.get(envelope, "summary", "")

        cond do
          # A zero-file reply is usually the SIZE RULE handoff ("NEEDS THE
          # RESIDENT AGENT: …") — surface that summary so the owner sees WHY
          # and can bring the task to the resident agent, not a bare
          # "envelope had no files".
          files == [] and summary =~ ~r/resident agent/i ->
            {:handoff, summary}

          files == [] ->
            {:error, if(summary == "", do: "envelope had no files", else: summary)}

          true ->
            case validate(files) do
              :ok -> {:ok, summary == "" && "done" || summary, Enum.map(files, &write_file/1)}
              {:error, reason} -> {:error, reason}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def extract_json(output) do
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

  def validate(files) do
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

  # The panel is persistent chrome now: headline (current activity or last
  # outcome) + the numbered session history that :do+N indexes into.
  defp render(state, headline \\ nil) do
    session_lines =
      state.sessions
      |> Enum.with_index(1)
      |> Enum.map(fn {s, i} ->
        text("#{i}. #{String.slice(s.summary, 0, 44)} — #{s.host}", style: :caption)
      end)

    Surface.show(
      :modsmith,
      vstack(
        [
          text("ModSmith", style: :title),
          text(headline || state.last_status, style: :caption),
          divider()
        ] ++
          session_lines ++
          [text(":do new · :do+ refine last · :do+N refine #N", style: :caption)]
      ),
      title: "ModSmith",
      anchor: :right_of_main,
      width: 260
    )
  end
end
