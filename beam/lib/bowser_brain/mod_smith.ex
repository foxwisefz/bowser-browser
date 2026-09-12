defmodule BowserBrain.ModSmith do
  @moduledoc "Claude runner and mod generation contract. ModWorkshop owns the native creation flow and revision lifecycle."
  require Logger
  alias BowserBrain.Page
  @default_timeout_ms 900_000

  def modify(path), do: BowserBrain.ModWorkshop.modify(path)

  def parse_followup(rest) do
    case Integer.parse(rest) do
      {n, remainder} when n > 0 and (remainder == "" or binary_part(remainder, 0, 1) == " ") ->
        {n, String.trim(remainder)}

      _ ->
        {:latest, String.trim(rest)}
    end
  end

  def page_digest(webview, app) do
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
        if app,
          do: BowserBrain.Bridge.eval_site_js(app["id"], probe),
          else: Page.eval(probe, webview: webview)
      catch
        :exit, _ -> {:error, :timeout}
      end

    case result do
      {:ok, json} when is_binary(json) -> json
      _ -> "{}"
    end
  end

  def build_prompt(request, url, host, digest, existing, catalog) do
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

    PROFILE OWNERSHIP: ModSmith automatically tags new files with the selected profile. Untagged mods belong to Default. Preserve the tag when editing. Browser-wide mods affect only their owning profile. Panels, toolbars, themes, events and site payloads stay in that profile. Use distinct filenames and module names for separate profiles.

    MOD API (for tier "mod"):
    defmodule MyMod do use BowserBrain.Mod          # add host: "site" per SCOPE RULE
      def init_mod(_opts), do: %{}                # state
      def handle_event(event, state), do: state   # events are string-keyed maps
    end
    Events: "url_changed"(url,webview) "title_changed"(title) "load_status"(status 0|2)
    "chrome_click"(id) "omnibar_command"(text) "store_changed"(mod,key) "page"(payload via window.bowser.emit in
    injected JS) "tab_opened"(webview,opener) "tab_activated"(webview) "hello" "mod_reloaded".
    HOT RELOAD KEEPS OLD PROCESS STATE: init_mod is NOT called again. When
    adding state keys, normalize at the start of EVERY event before reading
    them: state = Map.merge(%{view: :welcome, keyword: ""}, state), using YOUR
    actual defaults. Delegate to private event handlers after normalization.
    Preserve existing values; never assume state.new_key or %{state | new_key: x}
    is safe merely because the new init_mod defines it. Test mod_reloaded with
    the previous state shape (including %{}), not only a fresh process.
    APIs: BowserBrain.Browser.navigate(url); BowserBrain.Page.eval(js, webview: 0) ->
    {:ok,val}; Page.set_styles([css]); Page.set_scripts([js]) (engine-injected, owner-keyed);
    BowserBrain.Chrome.add_button(id, title, symbol: "sfsymbol");
    Chrome.put_toolbar("status", BowserBrain.View.hstack([
      BowserBrain.View.text("Ready"), BowserBrain.View.button("Action", event: "action")]),
      edge: :bottom, size: 28, style: %{background: "#C0C0C0", foreground: "#000000", border: "#808080"}).
    Native bars support edge: :top/:bottom/:left/:right; size: 16..200 points
    (height horizontally, width vertically). Use normal View DSL controls.
    They reserve webpage space rather than cover content. All browser windows
    inherit them; clicks are surface events with surface: "toolbar:status",
    id: the control event, and webview: the clicked window's active tab.
    Call in init_mod and mod_reloaded. Chrome.remove_toolbar(id) removes your
    bar; ownership cleanup and reconnect replay are automatic. Same ids shadow
    older owners. Up to 16 bars; ids sort alphabetically within each edge.
    Toolbars are browser-wide; for per-tab labels update on tab_activated.
    Use the toolbars MCP tool to inspect state after put_mod. No screenshot claim.
    Full-window borders use Chrome.set_theme keys window_border: "#808080",
    window_border_width: 0..12, window_border_style: "flat" or "beveled".
    These draw an inner outline on ALL four edges and reserve border space;
    they do not change macOS window shape, shadow, or native traffic lights.
    BowserBrain.Chrome.set_theme(%{background: "#0047AB", foreground: "#FFFFFF",
      button_background: "#C0C0C0", button_foreground: "#101010", accent: "#FFD700",
      border: "#808080", button_style: "beveled", show_navigation: true,
      title_size: 13, corner_radius: 2}) -> :ok | {:error, :invalid_theme}.
    THIS STYLES THE NATIVE BROWSER SHELL, not websites. Browser skins (including
    classic AOL colors and silver beveled navigation buttons) ARE in scope:
    create a browser-wide tier-mod and call set_theme in init_mod and on
    mod_reloaded. Keys are optional; colors MUST be #rrggbb; button_style is
    "flat" or "beveled"; title_size 9..16; corner_radius 0..12; show_navigation
    is boolean. No arbitrary native CSS or layout changes. There is no native
    tab strip: tab UI is a separate mod Surface. Do not claim to have styled
    tabs with set_theme. Chrome.theme() reads the effective map;
    Chrome.reset_theme() removes only the caller's theme. Themes replay on
    reconnect and are automatically removed when their owning mod stops, so
    Disable and file Undo restore the previous skin. Do not persist them in settings.
    The shell_theme MCP tool reads the brain's effective theme; this is state
    verification, not a screenshot. Never report visual checks you did not perform.
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
    NATIVE SETTINGS: Surface.show(id, tree, kind: :settings, title: "T", order: 30)
    registers a native preferences category. Use fields([field("Name:", input(:name),
    key: :name), ...]) for aligned forms, grid(children, columns: 3), group(label, tree),
    and list_detail([%{id: "work", title: "Work", symbol: "briefcase", detail: tree}]).
    form("unique-form-key", string_keyed_values, content, event: :save, required: [:name],
    response: state.response) keeps local drafts and supplies Save/Revert. input(name,
    kind: :text|:toggle|:color|:choice, label: ...) binds to that draft; choice options are
    [%{value: "star", label: "Star", symbol: "star"}] (or path: for images), columns: 4.
    Save's event value is %{"request_id"=>uuid,"values"=>draft}. Validate/persist in
    the brain, update values, and re-show the form with response:
    form_response(uuid, {:ok, saved_values}) or {:error, %{"field"=>"message"}}.
    Use require_changes: false for creation. sheet(key, label, tree, width: 480) and
    popover(key, label, tree, width: 320) present trees natively; popover inputs inherit
    their enclosing form. Sheet forms can set dismiss_on_success: true and
    dismiss_on_cancel: true, cancel_label: "Cancel". action(label, event:, role: :primary
    or :destructive, disabled:, shortcut: :default|:cancel) is a native button;
    action(label, action: :dismiss) closes a presentation. Use ui(node, key: stable_id,
    padding: 16, fill_width: true, min_width: 200, accessibility_label: ..., help: ...)
    for shared options. Give reordered siblings stable keys; form keys must be unique
    across the surface. Use text(..., style: :heading) for settings headings. Layout
    settings as focused editors and separate creation sheets, not a stack of every
    editable record. button() creates a panel row, not a native form action.
    COMPOSABLE WEBSITE LAYOUT: alias BowserBrain.{Layout, Surface}.
    Surface.create_tab(wv, url) -> {:ok, state} with "created" => background tab ID.
    Build arbitrary arrangements from Layout.webview(id, opts \\ []),
    Layout.row(children, opts \\ []), and Layout.column(children, opts \\ []).
    Nest rows (left-to-right) and columns (top-to-bottom) as needed. Every node
    accepts weight: (any positive relative value, default 1), min_width: and
    min_height: (nonnegative points, default 0). Containers additionally accept
    resizable: true/false (default true) to enable/fix their native dividers.
    Example: Layout.row([Layout.webview(a, weight: 2),
      Layout.column([Layout.webview(b), Layout.webview(c, min_height: 180)])]).
    Surface.layout(wv, tree) applies the tree atomically; Surface.tab_layout(wv)
    returns "tabs", "panes", "active", and "tree" with CURRENT divider weights;
    Surface.reset_layout(wv) returns to the active page without closing tabs.
    Surface calls return {:ok, state} or {:error, reason}; handle errors.
    Leaves are unique existing tab IDs in the same window/profile. The structural
    budget is 16 levels and 256 nodes, not a prescribed pane count or template.
    Website views keep DOM/navigation/login state. Minimum sizes are honored
    when they fit; an undersized window compresses them proportionally.
    Clicking a leaf selects it for navigation. Closing a tab prunes only that
    leaf and simplifies single-child containers. Selecting a tab outside the
    tree resets layout. Saved apps excluded. Layout ends with the native window.
    Use website_layout MCP actions get/create_tab/set/reset. set takes JSON tree:
    {"type":"row","children":[{"type":"webview","webview":a},
      {"type":"column","children":[{"type":"webview","webview":b},
        {"type":"webview","webview":c,"min_height":180}]}]}.
    All node options use the same snake_case keys. Runtime layout/tab creation
    is not file Undo. Build apply/reset controls, reuse IDs from get, refresh IDs
    after hello, and avoid creating tabs on every init/activation event.
    Compose the user's requested layout with these primitives; do not defer
    resizable website-layout requests to a resident agent.

    NATIVE VERIFICATION: native_screenshot captures the selected visible browser
    window, including native toolbar pixels, and returns an image and window id.
    Use native_click(x:, y:, window:) on controls visible in that screenshot;
    coordinates are window points from top-left. Screenshot again after clicking.
    These tools target the browser window, not separate floating panels or websites.
    A capture permission error is a verification limitation; do not claim success.
    NATIVE IMAGES: BowserBrain.View.image(path: "/absolute/path/logo.png", size: 48)
    displays an existing local image in a native Surface OR Chrome.put_toolbar
    view tree. For example hstack([image(path: "/absolute/path/logo.png", size: 48),
    text("Welcome")]) is valid toolbar content; use enough toolbar height for
    the image and padding. The current renderer sizes local images to a square
    of size x size points, so prepare square artwork to avoid distortion.
    image("globe") displays an SF Symbol; image(path: path, symbol: "photo", size: 48)
    uses the symbol as fallback if the file cannot be loaded. A bare string is
    a SYMBOL name, not an image path or URL. Standard button(...) and
    Chrome.add_button accept symbol icons, not arbitrary custom image labels.
    Custom local images in toolbar content ARE supported; never say native
    toolbars are restricted to system icons. Create original vector artwork using
    put_asset(name: "logo.svg", content: self-contained_svg_source), then use its
    returned image_path with View.image(path: image_path, size: 48). SVG is supported
    by the native image loader. Keep artwork self-contained (no scripts, external
    resources, or entities); use shapes, paths and inline colors. The tool records
    Undo history. Reference the installed relative asset path in final files.
    Raster uploads are not available here; existing accessible local PNG paths work.
    Never claim visual verification merely because an asset path is in a view tree.
    PANEL RULE: panel close is core behavior and suppresses automatic re-shows.
    The owner can reopen it through View > <title>; Surface.reshow(id)
    also explicitly restores it. No Panels mod is required.
    The panel chrome already shows the title and a close button —
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
    (value = item id). Strip options: header: / footer: ordinary view trees,
    header_height: / footer_height: points (0–240, default 48), header_outside: true
    excludes the header from the notch backing, chrome: "notch", background: hex.
    profile_avatar(profile_id) / profile_avatar(profile_id, opts), and
    profile_name(profile_id) / profile_name(profile_id, opts),
    bind to local profile identity (no remote asset URL); size: points (8–128).
    Avatar badge: true adds 7pt padding, a black circle and profile-tint border;
    size: 18 gives a 32pt badge. Name accepts color: hex and shared ui layout opts.
    Example: magnify_strip(items, header: profile_avatar("default", size: 18,
    badge: true), header_height: 82, header_outside: true, chrome: "notch").
    New renderer options require a native build supporting them.
    EXACT hello shape: %{"event"=>"hello", "tabs"=>[%{"id"=>wv,
    "url"=>u|nil, "title"=>t?, "favicon"=>path?}], "active"=>wv? (TOP-LEVEL)}. Live
    favicon updates: "favicon_changed" {webview, path}. Focus/close tabs with
    BowserBrain.Surface.activate_tab(wv) / Surface.close_tab(wv).
    There is NO native tab bar: one window holds N in-memory webviews and tab UI
    is entirely mod-owned. Website layout primitives can mount several together. Chrome.open_tab(url, activate: false) makes a tab;
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

  @finish_ms 240_000
  def run_claude(prompt, resume, on_progress, app) do
    settings = BowserBrain.Settings.all()

    case {System.find_executable("claude"), auth_route(settings)} do
      {nil, _route} ->
        {nil,
         {:error,
          "claude CLI not found on PATH — install it, then sign in or set up a router in :settings"}}

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
            mcp_args(app) ++
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

          {:done, code, events, raw, known_session} ->
            {result_session, text} = stream_result(events)
            detail = text || Enum.join(raw, " ")

            {result_session || known_session || resume,
             {:error,
              "claude exited #{code}: #{String.slice(detail, 0, 300)} | #{auth_hint(route)}"}}

          # Out of time with a known session: the work is in the CLI's
          # transcript — resume it and ask for the envelope NOW instead of
          # throwing the run away (the follow-tracker run died this way).
          {:timeout, session} when is_binary(session) ->
            on_progress.("⏱ time budget hit — asking for the envelope now")

            finish_args =
              [
                "-p",
                finish_prompt(),
                "--output-format",
                "stream-json",
                "--verbose",
                "--resume",
                session
              ] ++
                mcp_args(app) ++ model_args()

            case run_port(claude, finish_args, env, @finish_ms, on_progress) do
              {:done, 0, events, _raw, _} ->
                case stream_result(events) do
                  {new_session, text} when is_binary(text) and text != "" ->
                    {new_session || session, {:output, text}}

                  _ ->
                    {session,
                     {:error,
                      "timed out after #{div(timeout, 1000)}s; finish reply empty — session saved, :do+ to continue"}}
                end

              _ ->
                {session,
                 {:error,
                  "timed out after #{div(timeout, 1000)}s — session saved, :do+ to continue"}}
            end

          {:timeout, _none} ->
            {nil, {:error, "claude timed out after #{div(timeout, 1000)}s"}}
        end
    end
  end

  @heartbeat_ms 30_000

  @doc "What a run that ran out of time is asked on resume. Public for tests."
  def finish_prompt do
    """
    TIME BUDGET EXCEEDED — stop working now. Reply with ONLY the JSON envelope
    (same contract) for whatever is complete and working. Reference unchanged
    installed drafts by path; include contents only for new or changed files, and describe what is unfinished in "notes". If nothing is usable
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

    stream_loop(port, now + timeout, on_progress, %{
      events: [],
      raw: [],
      partial: "",
      session: nil,
      started: now
    })
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
                if String.trim(line) == "",
                  do: acc,
                  else: %{acc | raw: Enum.take([line | acc.raw], 40)}
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
              v when is_binary(v) and v != "" ->
                v |> String.replace(~r/\s+/, " ") |> String.slice(0, 70)

              _ ->
                nil
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
          |> Enum.flat_map(fn
            %{"message" => %{"content" => c}} when is_list(c) -> c
            _ -> []
          end)
          |> Enum.flat_map(fn
            %{"type" => "text", "text" => t} -> [t]
            _ -> []
          end)
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
  def declare_settings do
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
  @mcp_tools "mcp__bowser__website_layout,mcp__bowser__native_screenshot,mcp__bowser__native_click,mcp__bowser__put_asset,mcp__bowser__toolbars,mcp__bowser__put_mod,mcp__bowser__shell_theme,mcp__bowser__list_tabs,mcp__bowser__page_eval," <>
               "mcp__bowser__page_html,mcp__bowser__put_payload,mcp__bowser__list_mods,mcp__bowser__read_mod,mcp__bowser__store_get,mcp__bowser__store_put"

  defp mcp_args(app) do
    name = if app, do: "agent-mcp-#{app["id"]}.json", else: "agent-mcp.json"
    config = Path.join(BowserBrain.Paths.home(), name)

    env =
      if app,
        do: %{"BOWSER_SITE_APP_ID" => app["id"], "BOWSER_HOME" => BowserBrain.Paths.home()},
        else: %{"BOWSER_HOME" => BowserBrain.Paths.home()}

    env = Map.put(env, "BOWSER_MODSMITH_RUN", Process.get(:modsmith_run, ""))
    File.mkdir_p!(Path.dirname(config))

    File.write!(
      config,
      JSON.encode!(%{
        mcpServers: %{
          bowser: %{command: BowserBrain.Paths.mcp_bridge(), args: [], env: env}
        }
      })
    )

    ["--mcp-config", config, "--allowedTools", @mcp_tools] ++
      ["--tools", "", "--strict-mcp-config", "--disable-slash-commands"] ++ isolation_args()
  end

  @doc "Keep embedded ModSmith runs independent of developer project customizations, preserving OAuth."
  def isolation_args do
    ["--setting-sources", "", "--settings",
      JSON.encode!(%{disableAllHooks: true, autoMemoryEnabled: false, claudeMdExcludes: ["**"]}),
      "--system-prompt",
      "You are ModSmith, Bowser's browser customization agent. Follow the supplied workspace contract and API guide. Use only the provided browser tools. Return the requested JSON result and report observed failures precisely."]
  end

  # Routers serve their own model ids; the CLI's default may not exist there.
  #   :set modsmith_model <id-your-router-serves>
  defp model_args do
    case BowserBrain.Settings.get("modsmith_model") do
      model when is_binary(model) and model != "" -> ["--model", model]
      _ -> []
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
            {:ok, _} ->
              {:cont, :ok}

            {:error, {meta, message, token}} ->
              {:halt,
               {:error,
                "mod syntax error #{inspect(meta)}: #{inspect(message)} #{inspect(token)}"}}
          end

        true ->
          {:cont, :ok}
      end
    end)
  end
end
