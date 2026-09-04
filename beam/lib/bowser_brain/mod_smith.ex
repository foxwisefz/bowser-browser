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
  # 600s killed the follow-tracker run mid-envelope (bowser-browser-XXX):
  # compositions with live verification need longer, and a timeout now
  # salvages via resume instead of discarding.
  @default_timeout_ms 900_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
    # sessions: numbered refinement history, newest first, persisted to disk —
    # the claude CLI keeps its transcripts on disk, so --resume stays valid
    # across brain AND engine restarts (bowser-browser-lv4).
    {:ok, %{active: 0, urls: %{}, busy: nil, sessions: load_sessions(), last_status: "Ready.", progress: []}}
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

  @doc "Prefill the panel to modify one existing file — the ✎ in the Mods window."
  def modify(path), do: GenServer.cast(__MODULE__, {:modify, path})

  @impl true
  def handle_cast({:modify, path}, state) do
    state = Map.put(state, :target, %{kind: :modify, path: path})
    ensure_visible()
    render(state)
    {:noreply, state}
  end

  # -- the panel is interactive (bowser-browser-y7g follow-up): type a request,
  # click a session to refine it, ✕ to go back to a fresh request.
  def handle_info(
        {:browser_event, %{"event" => "surface", "surface" => "modsmith", "id" => "request", "value" => text}},
        state
      ) do
    text = text |> to_string() |> String.trim()

    cond do
      state.busy != nil ->
        render(state, "Busy with: #{state.busy}")
        {:noreply, state}

      text == "" ->
        {:noreply, state}

      true ->
        case request_for(Map.get(state, :target), state.sessions, text) do
          {:error, reason} ->
            render(state, reason)
            {:noreply, state}

          {request, opts} ->
            {:noreply, start_request(request, Map.put(state, :target, nil), opts)}
        end
    end
  end

  def handle_info(
        {:browser_event, %{"event" => "surface", "surface" => "modsmith", "id" => "pick", "value" => n}},
        state
      ) do
    n = to_int(n)
    target = if fetch_session(state.sessions, n), do: %{kind: :refine, n: n}, else: nil
    state = Map.put(state, :target, target)
    render(state)
    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "surface", "surface" => "modsmith", "id" => "new"}}, state) do
    state = Map.put(state, :target, nil)
    render(state)
    {:noreply, state}
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

  # Live narration while the agent works (bowser-browser-y7g): what it is
  # reading, probing, installing — so "Working on…" is no longer a black box.
  def handle_info({:smith_progress, line}, %{busy: busy} = state) when busy != nil do
    progress = Enum.take([line | Map.get(state, :progress, [])], 8)
    BowserBrain.ModLog.log("modsmith", line)
    state = Map.put(state, :progress, progress)
    render(state, "Working on: #{busy}")
    {:noreply, state}
  end

  def handle_info({:smith_progress, _line}, state), do: {:noreply, state}

  def handle_info({:smith_done, request, session, resumed, host, result}, state) do
    state = Map.put(state, :progress, [])

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

        # A failed run with a known session is still resumable — keep it in
        # the list so :do+N / a click can pick it up and finish.
        sessions =
          if session do
            remember_session(state.sessions, %{
              id: session,
              request: request,
              summary: "⏱ #{String.slice(reason, 0, 56)}",
              host: host,
              at: System.system_time(:millisecond),
              refined: resumed
            })
          else
            state.sessions
          end

        if session, do: persist_sessions(sessions)
        state = %{state | busy: nil, sessions: sessions, last_status: "Failed: #{String.slice(reason, 0, 120)}"}
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
        build_prompt(
          request,
          url,
          host,
          page_digest(state.active),
          SiteMods.payloads_for(host),
          BowserBrain.ModCatalog.summary()
        )
      end

    render(%{state | busy: request}, "Working on: #{request}")
    parent = self()

    Task.start(fn ->
      on_progress = fn line -> send(parent, {:smith_progress, line}) end
      {session, result} = run_claude(prompt, resume, on_progress)
      send(parent, {:smith_done, request, session, resume, host, result && install(result, host)})
    end)

    %{state | busy: request}
  end

  @doc """
  What a panel submission means given the picked target: a fresh request, a
  refinement of session N (resumed), or a change to one existing file — the
  MODIFY rule + read_mod then make the agent edit that file in place.
  Public for tests.
  """
  def request_for(nil, _sessions, text), do: {text, []}

  def request_for(%{kind: :modify, path: path}, _sessions, text) do
    {"Modify the existing file #{path} — read_mod it first and return the SAME path " <>
       "with the complete updated content. Change: #{text}", []}
  end

  def request_for(%{kind: :refine, n: n}, sessions, text) do
    case fetch_session(sessions, n) do
      nil -> {:error, "Session ##{n} is gone — pick another"}
      session -> {text, [resume: session.id]}
    end
  end

  @doc "Textfield hint for the current target. Public for tests."
  def placeholder_for(nil), do: "What should this page do? ⏎"
  def placeholder_for(%{kind: :modify, path: path}), do: "Change #{Path.basename(path)} how? ⏎"
  def placeholder_for(%{kind: :refine, n: n}), do: "Refine ##{n} how? ⏎"

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) do
    case Integer.parse(to_string(v)) do
      {n, _} -> n
      _ -> 0
    end
  end

  # A panel toggled off in the View menu swallows shows; un-suppress it so
  # a ✎ click from the Mods window actually brings ModSmith up.
  defp ensure_visible do
    case Enum.find(Surface.list(), &(&1.id == "modsmith")) do
      %{closed: true} -> Surface.toggle(:modsmith)
      _ -> :ok
    end
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
      Path.join(BowserBrain.Paths.home(), "modsmith-sessions.json")
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

  defp build_prompt(request, url, host, digest, existing, catalog) do
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
    page_eval "location.reload()"), list_mods (every existing mod/payload:
    path, on/off, scope, what it does), read_mod (full source of one by path),
    store_get / store_put (a mod's durable Store — read it to check what a mod
    remembered; SEED it to verify time-based behavior without waiting). WORKFLOW: inspect the real DOM first; draft;
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

    SIZE RULE: you are the small fast path — but COMPOSITIONS of the
    primitives in this prompt are IN scope even when they span concerns. An
    injected-JS page hook (window.bowser.emit) + Store for memory + processing
    on url_changed/tab_activated/page events + a Surface panel with buttons is
    ONE tier-"mod" file: build it. Verify stateful, time-based behavior by
    SEEDING — store_put an entry with an old timestamp, reload the page,
    confirm the mod acted on it. Hand off ONLY when the request needs a
    genuinely new brain-side service: browsing in the background while the
    owner is elsewhere, scheduled work when no tab is open, audio/media
    pipelines, external integrations beyond one fetch. Then reply IMMEDIATELY
    with a zero-file envelope whose summary starts "NEEDS THE RESIDENT AGENT:"
    plus one line on why. A fast honest handoff beats a ten-minute timeout.

    MODIFY RULE: the EXISTING MODS catalog below is what the owner already has.
    If the request refers to behavior that exists — by name, by what it does,
    or by its site — MODIFY that file: read_mod it first, keep everything you
    were not asked to change, and return the SAME path with the complete
    updated content. Never create a second mod or payload for behavior that
    already exists. A file marked OFF still counts: modify it and say in the
    summary that it is disabled (the owner toggles it in :mods).

    TIME BUDGET: about #{div(timeout_ms(BowserBrain.Settings.get("modsmith_timeout_ms")), 60_000)}
    minutes total, verification included. Work incrementally: install drafts early
    (put_payload / store_put), and return the envelope as soon as the core works —
    unfinished parts go in "notes". If time runs out you will be asked to return
    what you have; a partial working envelope beats a lost run.

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
    "chrome_click"(id) "omnibar_command"(text) "store_changed"(mod,key) "page"(payload via window.bowser.emit in
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
    value:, label:), textfield(event, placeholder:, value:), colorpicker(event, value: "#rrggbb",
    label:) (sends "#rrggbb", debounced), divider(), particles(chars: ["♪"],
    rate: 3.0, active: bool). Surface events arrive as
    %{"event"=>"surface","surface"=>id,"id"=>ev,"value"=>v}.
    PANEL RULE: the panel chrome already shows the title and a close button —
    NEVER add a title text of your own. Panels size to their content (up to
    480px) and the owner can resize and move them; still prefer one item per
    row (vstack) over crowded hstacks, keep labels short, and put counts in a
    single caption line.
    STORE (durable memory across days and restarts): BowserBrain.Store.get(__MODULE__,
    "key", default) / put(__MODULE__, "key", value) / update(__MODULE__, "key", default,
    fn v -> ... end) / delete / all. Values are JSON-shaped and come back with STRING
    keys; one file per mod under ~/.bowser/data/. When the Store is written from
    outside the mod (you seeding with store_put, the owner editing) the mod gets
    "store_changed"(mod, key): a mod that renders a panel from the Store MUST handle
    it by re-rendering. Always REMOVE the fixtures you seeded when done, and the
    panel will follow. Anything that must survive a restart
    (who you followed and when, counters, owner choices) lives here, never only in
    process state. Timestamps: System.system_time(:second) integers.
    ACTION BUDGET: before ANY automated site action (follow, unfollow, like, post, DM)
    call BowserBrain.Budget.take(__MODULE__, host) and STOP on {:error, :exhausted}
    (surface it; never bypass). The owner tunes `action_budget` in :settings
    (default 30 per mod per host per day).
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
    Existing payloads for #{host} (full content):
    #{existing_block}
    EXISTING MODS AND PAYLOADS, all sites (read_mod for full source):
    #{catalog}

    OWNER REQUEST: #{request}
    """
  end

  defp run_claude(prompt, resume, on_progress) do
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

        # stream-json (needs --verbose in --print mode): one JSON event per
        # line as the agent works, so progress narrates live instead of
        # arriving as one blob after ten minutes (bowser-browser-y7g).
        args =
          ["-p", prompt, "--output-format", "stream-json", "--verbose"] ++
            mcp_args() ++
            model_args() ++
            if(resume, do: ["--resume", resume], else: [])

        Logger.info(
          "modsmith: exec claude <#{byte_size(prompt)}B prompt> " <>
            "#{Enum.join(model_args(), " ")}#{if resume, do: " --resume #{resume}"} " <>
            "| env: #{Enum.map_join(env, ",", &elem(&1, 0))}"
        )

        timeout = timeout_ms(BowserBrain.Settings.get("modsmith_timeout_ms"))

        case run_port(claude, args, env, timeout, on_progress) do
          {:done, 0, events, raw, _session} ->
            case stream_result(events) do
              {session, text} when is_binary(text) and text != "" -> {session, {:output, text}}
              _ -> {nil, {:output, Enum.join(raw, "\n")}}
            end

          {:done, code, events, raw, _session} ->
            {_session, text} = stream_result(events)
            detail = text || Enum.join(raw, " ")
            {nil, {:error, "claude exited #{code}: #{String.slice(detail, 0, 300)} | #{auth_hint(route)}"}}

          # Out of time with a known session: the work is in the CLI's
          # transcript — resume it and ask for the envelope NOW instead of
          # throwing the run away (the follow-tracker run died this way).
          {:timeout, session} when is_binary(session) ->
            on_progress.("⏱ time budget hit — asking for the envelope now")

            finish_args =
              ["-p", finish_prompt(), "--output-format", "stream-json", "--verbose", "--resume", session] ++
                mcp_args() ++ model_args()

            case run_port(claude, finish_args, env, @finish_ms, on_progress) do
              {:done, 0, events, _raw, _} ->
                case stream_result(events) do
                  {new_session, text} when is_binary(text) and text != "" ->
                    {new_session || session, {:output, text}}

                  _ ->
                    {session, {:error, "timed out after #{div(timeout, 1000)}s; finish reply empty — session saved, :do+ to continue"}}
                end

              _ ->
                {session, {:error, "timed out after #{div(timeout, 1000)}s — session saved, :do+ to continue"}}
            end

          {:timeout, _none} ->
            {nil, {:error, "claude timed out after #{div(timeout, 1000)}s"}}
        end
    end
  end

  @finish_ms 240_000
  @heartbeat_ms 30_000

  @doc "What a run that ran out of time is asked on resume. Public for tests."
  def finish_prompt do
    """
    TIME BUDGET EXCEEDED — stop working now. Reply with ONLY the JSON envelope
    (same contract) for whatever is complete and working, with FULL file
    contents, and describe what is unfinished in "notes". If nothing is usable
    yet, reply with a zero-file envelope whose summary starts
    "NEEDS THE RESIDENT AGENT:" and say what was blocking.
    """
  end

  # Launch the CLI and stream it. sh wrapper: claude waits 3s on the port's
  # dangling stdin without an explicit < /dev/null.
  defp run_port(claude, args, env, timeout, on_progress) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 4_000_000},
        {:args, ["-c", ~s(exec "$0" "$@" < /dev/null), claude | args]},
        {:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}
      ])

    now = System.monotonic_time(:millisecond)
    stream_loop(port, now + timeout, on_progress, %{events: [], raw: [], partial: "", session: nil, started: now})
  end

  @doc false
  # Public so tests can drive it with a fake port tag (any ref works).
  def stream_loop(port, deadline, on_progress, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      catch_close(port)
      {:timeout, acc.session}
    else
      receive do
        {^port, {:data, {:noeol, chunk}}} ->
          stream_loop(port, deadline, on_progress, %{acc | partial: acc.partial <> chunk})

        {^port, {:data, {:eol, chunk}}} ->
          line = acc.partial <> chunk
          acc = %{acc | partial: ""}

          acc =
            case JSON.decode(line) do
              {:ok, event} when is_map(event) ->
                for text <- progress_lines(event), do: on_progress.(text)
                %{acc | events: [event | acc.events], session: session_of(event) || acc.session}

              _ ->
                if String.trim(line) == "", do: acc, else: %{acc | raw: Enum.take([line | acc.raw], 40)}
            end

          stream_loop(port, deadline, on_progress, acc)

        {^port, {:exit_status, code}} ->
          {:done, code, Enum.reverse(acc.events), Enum.reverse(acc.raw), acc.session}
      after
        min(remaining, @heartbeat_ms) ->
          # A long generation is one silent message: say we're alive.
          if remaining > @heartbeat_ms do
            elapsed = div(System.monotonic_time(:millisecond) - acc.started, 1000)
            on_progress.("… still working (#{elapsed}s, writing)")
          end

          stream_loop(port, deadline, on_progress, acc)
      end
    end
  end

  @doc "The CLI session id a stream announces (init or result event); nil otherwise. Public for tests."
  def session_of(%{"type" => "system", "session_id" => sid}) when is_binary(sid), do: sid
  def session_of(%{"type" => "result", "session_id" => sid}) when is_binary(sid), do: sid
  def session_of(_event), do: nil

  defp catch_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Human lines for one stream-json event: assistant prose (trimmed) and tool
  calls as `→ tool detail`. Nothing for system/user/result events. Public
  for tests.
  """
  def progress_lines(%{"type" => "assistant", "message" => %{"content" => content}})
      when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => text} ->
        case text |> String.trim() |> String.replace(~r/\s+/, " ") do
          "" -> []
          t -> [String.slice(t, 0, 160)]
        end

      %{"type" => "tool_use", "name" => name} = call ->
        input = Map.get(call, "input", %{})
        tool = name |> String.replace_prefix("mcp__bowser__", "")

        detail =
          Enum.find_value(["path", "selector", "name", "js"], "", fn key ->
            case input[key] do
              v when is_binary(v) and v != "" -> v |> String.replace(~r/\s+/, " ") |> String.slice(0, 70)
              _ -> nil
            end
          end)

        [String.trim("→ #{tool} #{detail}")]

      _ ->
        []
    end)
  end

  def progress_lines(_event), do: []

  @doc """
  The final answer from a stream: `{session_id, text}` from the terminating
  result event, else the assistant's concatenated prose. Public for tests.
  """
  def stream_result(events) do
    case Enum.find(Enum.reverse(events), &(&1["type"] == "result")) do
      %{"result" => text} = result when is_binary(text) ->
        {result["session_id"], text}

      _ ->
        text =
          events
          |> Enum.filter(&(&1["type"] == "assistant"))
          |> Enum.flat_map(fn %{"message" => %{"content" => c}} when is_list(c) -> c; _ -> [] end)
          |> Enum.flat_map(fn %{"type" => "text", "text" => t} -> [t]; _ -> [] end)
          |> Enum.join("\n")

        {nil, if(text == "", do: nil, else: text)}
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
    BowserBrain.Budget.declare_setting()
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
               "mcp__bowser__page_html,mcp__bowser__put_payload,mcp__bowser__list_mods,mcp__bowser__read_mod,mcp__bowser__store_get,mcp__bowser__store_put"

  defp mcp_args do
    config = Path.join(BowserBrain.Paths.home(), "agent-mcp.json")

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
    target = Path.join(BowserBrain.Paths.home(), path)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, content)
    path
  end

  @doc """
  Status glyph/label/detail from the live headline or the last outcome:
  `{"●","Working",request}`, `{"✓","Done",summary}`, `{"✗","Failed",reason}`,
  `{"↗","Handed off",why}`, `{"○","Ready",nil}`. Public for tests.
  """
  def status_line(headline, last_status) do
    line = headline || last_status || "Ready."

    {glyph, label, detail} =
      cond do
        String.starts_with?(line, "Working on: ") -> {"●", "Working", String.replace_prefix(line, "Working on: ", "")}
        String.starts_with?(line, "Busy with: ") -> {"●", "Busy", String.replace_prefix(line, "Busy with: ", "")}
        String.starts_with?(line, "Done: ") -> {"✓", "Done", String.replace_prefix(line, "Done: ", "")}
        String.starts_with?(line, "Failed: ") -> {"✗", "Failed", String.replace_prefix(line, "Failed: ", "")}
        String.starts_with?(line, "↗ ") -> {"↗", "Handed off", String.replace_prefix(line, "↗ ", "")}
        line == "Ready." -> {"○", "Ready", nil}
        true -> {"·", line, nil}
      end

    {glyph, label, detail && String.slice(detail, 0, 110)}
  end

  @doc """
  The panel: request field, (target line), status + short mono log, then
  compact click-to-refine sessions. No inner title (the panel chrome has
  one), no hint footer (the placeholder says ⏎). Public for tests.
  """
  def tree(state, headline \\ nil) do
    target = Map.get(state, :target)
    {glyph, label, detail} = status_line(headline, state.last_status)

    mode =
      case target do
        nil ->
          []

        %{kind: :refine, n: n} ->
          s = fetch_session(state.sessions, n)
          summary = String.slice((s && s.summary) || "", 0, 34)
          [hstack([text("Refining ##{n} · #{summary}", style: :caption), spacer(), button("✕", event: "new", compact: true)])]

        %{kind: :modify, path: path} ->
          [hstack([text("Modifying #{Path.basename(path)}", style: :caption), spacer(), button("✕", event: "new", compact: true)])]
      end

    log =
      state
      |> Map.get(:progress, [])
      |> Enum.take(6)
      |> Enum.reverse()
      |> Enum.map(&text(&1, style: :mono))

    sessions =
      case state.sessions do
        [] ->
          [text("No sessions yet — type a request above.", style: :caption)]

        list ->
          list
          |> Enum.with_index(1)
          |> Enum.map(fn {s, i} ->
            picked = match?(%{kind: :refine, n: ^i}, target)

            row(s.summary,
              subtitle: "##{i} · #{s.host}" <> if(picked, do: " · refining", else: ""),
              symbol: if(picked, do: "checkmark.circle.fill", else: "clock"),
              event: "pick",
              payload: i
            )
          end)
      end

    vstack(
      [textfield("request", placeholder: placeholder_for(target))] ++
        mode ++
        [spacer(min: 2), text("#{glyph} #{label}", style: :title)] ++
        if(detail, do: [text(detail, style: :caption)], else: []) ++
        log ++
        [section("Sessions · click to refine")] ++
        sessions
    )
  end

  defp render(state, headline \\ nil) do
    Surface.show(:modsmith, tree(state, headline), title: "ModSmith", anchor: :right_of_main, width: 320)
  end
end
