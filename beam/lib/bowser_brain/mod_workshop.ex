defmodule BowserBrain.ModWorkshop do
  @moduledoc "Core ModSmith workflow: durable conversations, scoped runs and reversible file revisions."
  use GenServer
  alias BowserBrain.{ModRevision, ModSmith, Bridge, AppMods}
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def modify(path), do: GenServer.cast(__MODULE__, {:modify, path})

  def tool(token, tool, args) do
    case GenServer.call(__MODULE__, {:context, token}) do
      {:ok, run} ->
        cond do
          tool == "put_asset" and run.app == nil ->
            GenServer.call(__MODULE__, {:draft_asset, token, args}, 15_000)

          tool == "put_payload" ->
            GenServer.call(__MODULE__, {:draft, token, args}, 15_000)

          tool == "put_mod" and run.app == nil ->
            case GenServer.call(__MODULE__, {:draft_mod, token, args}, 110_000) do
              %{ok: true, installed: path} = reply ->
                runtime =
                  if ModRevision.actual_path(path) == path,
                    do: BowserBrain.Loader.load_now(ModRevision.absolute(path)),
                    else: %{ok: true, status: "disabled"}
                Map.merge(reply, %{ok: runtime.ok, runtime: runtime,
                  applies: "File recorded for Undo. Runtime result reports compilation and startup/reload; verify appearance separately."})
              reply -> reply
            end

          tool in ["native_screenshot", "native_click", "website_layout"] and run.app == nil ->
            BowserBrain.AgentPort.dispatch(%{"tool" => tool, "args" => Map.put(args, "webview", run.webview)})

          tool == "list_tabs" ->
            %{ok: true, active: run.webview, tabs: [%{webview: run.webview, url: run.url}]}

          tool in ["shell_theme", "toolbars"] and run.app == nil ->
            BowserBrain.AgentPort.dispatch(%{"tool" => tool})

          tool == "list_mods" and run.app == nil ->
            profile = Map.get(run, :profile, BowserBrain.ModScope.profile_of(run.webview))
            %{ok: true, mods: Enum.filter(BowserBrain.ModCatalog.catalog(), &(&1.profile == profile))}

          tool in ["read_mod", "store_get", "store_put"] and run.app == nil ->
            scoped_data_tool(run, tool, args)

          tool in ["page_eval", "page_html", "list_mods", "read_mod", "store_get", "store_put"] ->
            args = args |> Map.delete("site_app") |> Map.put("webview", run.webview)

            if run.app,
              do: AppMods.dispatch(tool, args, run.app["id"]),
              else: BowserBrain.AgentPort.dispatch(%{"tool" => tool, "args" => args})

          true ->
            %{ok: false, error: "Tool unavailable in ModSmith"}
        end

      {:error, reason} ->
        %{ok: false, error: reason}
    end
  end

  # Catalog visibility is not authorization: check the exact source/storage
  # target on every call, including disabled files and Elixir module aliases.
  defp scoped_data_tool(%{profile: profile}, "read_mod", %{"path" => path})
       when is_binary(profile) and profile != "" do
    with {:ok, actual, source} <- scoped_source(path),
         true <- BowserBrain.ModScope.source_profile(source) == profile do
      %{ok: true, path: actual, content: source}
    else
      _ -> scope_error()
    end
  end

  defp scoped_data_tool(%{profile: profile}, tool, %{"mod" => requested} = args)
       when tool in ["store_get", "store_put"] and is_binary(profile) and profile != "" and
              is_binary(requested) do
    mod = String.replace_prefix(requested, "Elixir.", "")

    if Regex.match?(~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/, mod) and
         module_owned_by?(mod, profile) do
      BowserBrain.AgentPort.dispatch(%{"tool" => tool, "args" => Map.put(args, "mod", mod)})
    else
      scope_error()
    end
  end

  defp scoped_data_tool(_, _, _), do: scope_error()
  defp scope_error, do: %{ok: false, error: "Mod is unavailable in this ModSmith profile"}

  defp scoped_source(path) when is_binary(path) do
    if (String.starts_with?(path, "mods/") or String.starts_with?(path, "sites/")) and
         ModRevision.allowed?(path) do
      actual = ModRevision.actual_path(path)
      case ModRevision.read(actual) do
        source when is_binary(source) -> {:ok, actual, source}
        _ -> :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  end
  defp scoped_source(_), do: :error

  defp module_owned_by?(mod, profile) do
    # Inspect all declarations, not just the visible profile. Ambiguous names
    # must never authorize access to the shared Store namespace. Never compile
    # source or intern model-controlled module names while checking ownership.
    owners =
      Path.wildcard(Path.join(BowserBrain.ModCatalog.mods_dir(), "*.ex{,.off}"))
      |> Enum.flat_map(fn file ->
        case scoped_source("mods/" <> Path.basename(file)) do
          {:ok, _, source} ->
            if mod in declared_mods(source), do: [BowserBrain.ModScope.source_profile(source)], else: []
          _ -> []
        end
      end)

    owners != [] and Enum.all?(owners, &(&1 == profile)) and runtime_owner_matches?(mod, profile)
  end

  defp runtime_owner_matches?(mod, profile) do
    # A live module can still belong to its previous profile after a file edit.
    module =
      try do
        String.to_existing_atom("Elixir." <> mod)
      rescue
        ArgumentError -> nil
      end

    if module == nil do
      true
    else
      case Registry.lookup(BowserBrain.ModRegistry, module) do
        [] -> true
        entries -> Enum.all?(entries, fn {pid, _} -> BowserBrain.ModScope.current(pid) == profile end)
      end
    end
  rescue
    _ -> false
  end

  defp declared_mods(source) do
    case Code.string_to_quoted(source, static_atoms_encoder: fn name, _ -> {:ok, name} end) do
      {:ok, ast} ->
        for {"defmodule", _, [{:__aliases__, _, names}, body]} <- statements(ast),
            is_list(body),
            Enum.all?(names, &is_binary/1),
            Enum.any?(statements(Keyword.get(body, :do)), fn
              {"use", _, [{:__aliases__, _, ["BowserBrain", "Mod"]} | _]} -> true
              _ -> false
            end),
            do: names |> Enum.join(".") |> String.replace_prefix("Elixir.", "")
      _ -> []
    end
  end

  defp statements({:__block__, _, statements}), do: statements
  defp statements(statement), do: [statement]

  @impl true
  def init(_) do
    Registry.register(BowserBrain.Events, :browser_event, nil)
    data = ModRevision.load() |> recover()
    {:ok, %{data: data, run: nil, active: 0, urls: %{}, progress: [], error: nil, accepted: nil}}
  end

  def recover(data) do
    projects =
      Enum.map(data["projects"], fn p ->
        p =
          if undo = p["pending_undo"] do
            r = Enum.find(p["revisions"], &(&1["id"] == undo))

            case r && ModRevision.restore(r) do
              :ok ->
                p
                |> Map.put(
                  "revisions",
                  Enum.map(p["revisions"], fn r ->
                    if r["id"] == undo, do: Map.put(r, "status", "undone"), else: r
                  end)
                )
                |> Map.put("status", "restored")
                |> Map.put("session", nil)
                |> Map.delete("pending_undo")

              _ ->
                Map.put(
                  p,
                  "summary",
                  "Restoration was interrupted. Your files are preserved; retry Undo."
                )
            end
          else
            p
          end

        revisions =
          Enum.map(p["revisions"], fn r ->
            if r["status"] == "working", do: Map.put(r, "status", "interrupted"), else: r
          end)

        if p["status"] == "working" do
          p
          |> Map.put("revisions", revisions)
          |> Map.put("status", "interrupted")
          |> Map.put(
            "summary",
            "The previous run was interrupted. Draft changes may still be active; you can undo or continue."
          )
        else
          Map.put(p, "revisions", revisions)
        end
      end)

    ModRevision.save(%{data | "projects" => projects})
  end

  @impl true
  def handle_info({:browser_event, %{"event" => "hello"} = event}, state) do
    ModSmith.declare_settings()
    BowserBrain.Chrome.register_command("do", "ModSmith — create a mod")
    BowserBrain.Chrome.register_command("do+", "ModSmith — refine the latest mod")
    urls = Map.new(event["tabs"] || [], fn t -> {t["webview"] || t["id"], t["url"] || ""} end)
    state = %{state | urls: Map.merge(state.urls, urls), active: event["active"] || state.active}
    publish(state)
    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "tab_activated", "webview" => wv}}, state),
    do: {:noreply, tap(%{state | active: wv}, &publish/1)}

  def handle_info(
        {:browser_event, %{"event" => "url_changed", "webview" => wv, "url" => url}},
        state
      ),
      do: {:noreply, %{state | urls: Map.put(state.urls, wv, url)}}

  def handle_info({:browser_event, %{"event" => "modsmith"} = event}, state) do
    state = action(state, event) |> Map.put(:error_client, client(event))
    publish(state, client(event), event["action"] == "open")
    {:noreply, state}
  rescue
    error ->
      state = %{state | error: Exception.message(error)}
      publish(state, client(event))
      {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "site_mod_request"} = event}, state) do
    handle_info(
      {:browser_event,
       Map.merge(event, %{"event" => "modsmith", "action" => "submit", "text" => event["request"]})},
      state
    )
  end

  def handle_info(
        {:browser_event, %{"event" => "omnibar_command", "text" => "do+" <> rest}},
        state
      ) do
    {index, text} = ModSmith.parse_followup(rest)
    projects = Enum.filter(state.data["projects"], &is_nil(&1["app"]))
    project = Enum.at(projects, if(index == :latest, do: 0, else: index - 1))

    event = %{
      "action" => if(text == "", do: "select", else: "submit"),
      "project" => project && project["id"],
      "text" => text
    }

    state = if project, do: action(state, event), else: %{state | error: "Create a mod first."}
    publish(state, "main", true)
    {:noreply, state}
  end

  def handle_info(
        {:browser_event, %{"event" => "omnibar_command", "text" => "do" <> rest}},
        state
      ) do
    state =
      if String.trim(rest) == "",
        do: state,
        else: action(state, %{"action" => "submit", "text" => String.trim(rest)})

    publish(state, "main", true)
    {:noreply, state}
  end

  def handle_info({:progress, token, line}, %{run: %{token: token}} = state) do
    state = %{state | progress: Enum.take(state.progress ++ [line], -80)}
    publish(state)
    {:noreply, state}
  end

  def handle_info({:finished, token, session, result} = message, %{run: %{token: token}} = state) do
    Process.demonitor(state.run.ref, [:flush])
    files = case result do
      {:output, output} ->
        case ModSmith.extract_json(output) do
          {:ok, %{"files" => files}} when is_list(files) -> resolve_drafts(state, files)
          _ -> []
        end
      _ -> []
    end
    case audit_gate(state, files, {:info, message}) do
      {:pending, state} -> {:noreply, state}
      outcome ->
        result = case outcome do
          :ready -> result
          {:error, reason} -> {:error, reason}
        end
        state = finish(state, session, result)
        publish(state)
        {:noreply, state}
    end
  end

  def handle_info({:audit_finished, ref, result}, %{pending_audit: %{ref: ref} = pending} = state) do
    Process.cancel_timer(pending.timer)
    if Process.alive?(pending.pid), do: Process.exit(pending.pid, :kill)
    state = Map.put(state, :pending_audit, nil)
    same_run = state.run != nil and state.run.token == pending.token
    valid_run = same_run and
      (state.urls[state.run.webview] == nil or URI.parse(state.urls[state.run.webview]).host == URI.parse(state.run.url).host)
    result = if valid_run, do: result, else: {:error, "The ModSmith run ended during security audit"}
    state = if result == :ok,
      do: Map.update(state, :audit_approvals, pending.keys, &(Enum.uniq(&1 ++ pending.keys))), else: state
    case {pending.continuation, result} do
      {{:call, request, from}, :ok} ->
        case handle_call(request, from, state) do
          {:reply, reply, state} ->
            GenServer.reply(from, reply)
            {:noreply, state}
          {:noreply, state} -> {:noreply, state}
        end
      {{:call, _, from}, {:error, reason}} ->
        GenServer.reply(from, %{ok: false, error: reason})
        {:noreply, state}
      {{:info, message}, :ok} -> handle_info(message, state)
      {{:info, {:finished, _, session, _}}, {:error, reason}} ->
        if same_run do
          state = finish(state, session, {:error, reason})
          publish(state)
          {:noreply, state}
        else
          {:noreply, state}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{run: %{ref: ref}} = state) do
    state = finish(state, nil, {:error, "Generation stopped: #{inspect(reason)}"})
    publish(state)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_cast({:modify, path}, state) do
    state = edit_existing(state, %{"path" => path})
    publish(state, "main", true)
    {:noreply, state}
  end

  @impl true
  def handle_call({:context, token}, _, state) do
    reply =
      case state.run do
        %{token: ^token} = run ->
          current = state.urls[run.webview]

          if run.app == nil and current != nil and
               URI.parse(current).host != URI.parse(run.url).host do
            {:error,
             "The target tab moved to a different site. Return to #{URI.parse(run.url).host} to continue."}
          else
            {:ok, run}
          end

        _ ->
          {:error, "This run has ended. Start a new refinement before changing files."}
      end

    {:reply, reply, state}
  end

  def handle_call({:draft, token, args}, _, %{run: %{token: token}} = state) do
    p = project(state, state.run.project)
    host = URI.parse(p["url"]).host

    path =
      if p["app"],
        do: "app-mods/#{p["app"]["id"]}/#{args["name"]}",
        else: "sites/#{args["host"] || host}/#{args["name"]}"

    if not is_binary(args["content"]) or not ModRevision.allowed?(path) do
      {:reply, %{ok: false, error: "Expected CSS/JS payload content and a scoped filename"}, state}
    else
    profile = Map.get(state.run, :profile, BowserBrain.ModScope.profile_of(state.run.webview))
    content = if p["app"], do: args["content"], else: BowserBrain.ModScope.tag(args["content"], profile, Path.extname(path))
    existing = ModRevision.absolute(ModRevision.actual_path(path))
    result = if is_nil(p["app"]) and File.exists?(existing) and BowserBrain.ModScope.file_profile(existing) != profile,
      do: {:error, "This payload belongs to another profile; choose a different name", state},
      else: write_files(state, [%{"path" => path, "content" => content}])
    case result do
      {:ok, state} ->
        {:reply, %{ok: true, installed: path, applies: "Live; revision recorded for Undo"}, state}

      {:error, reason, state} ->
        {:reply, %{ok: false, error: reason}, state}
    end
    end
  rescue
    _ -> {:reply, %{ok: false, error: "Invalid payload path or content"}, state}
  end

  def handle_call({:draft, _, _}, _, state), do: {:reply, %{ok: false, error: "Run ended"}, state}

  def handle_call({:draft_asset, token, args}, _, %{run: %{token: token, app: nil}} = state) do
    name = args["name"]
    if is_binary(name) and Regex.match?(~r/^[A-Za-z0-9_-][A-Za-z0-9._-]*\.svg$/, name) do
      path = "assets/#{state.run.project}/#{name}"
      case write_files(state, [%{"path" => path, "content" => args["content"]}]) do
        {:ok, state} ->
          {:reply, %{ok: true, installed: path, image_path: ModRevision.absolute(path)}, state}
        {:error, reason, state} -> {:reply, %{ok: false, error: reason}, state}
      end
    else
      {:reply, %{ok: false, error: "Expected an SVG filename without directories"}, state}
    end
  end
  def handle_call({:draft_asset, _, _}, _, state),
    do: {:reply, %{ok: false, error: "An active ModSmith run is required"}, state}

  def handle_call({:draft_mod, token, args} = request, from, %{run: %{token: token, app: nil}} = state) do
    name = args["name"]
    if is_binary(name) and Regex.match?(~r/^[A-Za-z0-9_-][A-Za-z0-9._-]*\.ex$/, name) do
      case audit_gate(state, [%{"path" => "mods/#{name}", "content" => args["content"]}], {:call, request, from}) do
        :ready -> draft_mod(args, state)
        {:pending, state} -> {:noreply, state}
        {:error, reason} -> {:reply, %{ok: false, error: reason}, state}
      end
    else
      {:reply, %{ok: false, error: "Expected a mod filename ending in .ex, without directories"}, state}
    end
  end

  def handle_call({:draft_mod, _, _}, _, state),
    do: {:reply, %{ok: false, error: "An active browser/site ModSmith run is required"}, state}

  defp draft_mod(args, state) do
    name = args["name"]

    if is_binary(name) and Regex.match?(~r/^[A-Za-z0-9_-][A-Za-z0-9._-]*\.ex$/, name) do
      path = "mods/#{name}"

      profile = Map.get(state.run, :profile, BowserBrain.ModScope.profile_of(state.run.webview))
      source = BowserBrain.ModScope.tag(args["content"], profile)
      existing = ModRevision.absolute(ModRevision.actual_path(path))
      result = if File.exists?(existing) and BowserBrain.ModScope.file_profile(existing) != profile,
        do: {:error, "This mod belongs to another profile; choose a different name", state},
        else: write_files(state, [%{"path" => path, "content" => source}])
      case result do
        {:ok, state} ->
          {:reply, %{ok: true, installed: path,
            applies: "Written with Undo history. Loader compiles asynchronously; verify runtime state before reporting success."}, state}
        {:error, reason, state} ->
          {:reply, %{ok: false, error: reason}, state}
      end
    else
      {:reply, %{ok: false, error: "Expected a mod filename ending in .ex, without directories"}, state}
    end
  end


  defp client(event), do: get_in(event, ["app", "id"]) || "main"
  defp project(state, id), do: Enum.find(state.data["projects"], &(&1["id"] == id))
  defp selection_key(state, "main") do
    case BowserBrain.ModScope.profile_of(state.active) do
      "default" -> "main"
      profile -> "main:" <> profile
    end
  end
  defp selection_key(_state, client), do: client
  defp selected(state, client), do: state.data["selected"][selection_key(state, client)]
  defp persist(state), do: %{state | data: ModRevision.save(state.data)}

  defp put_project(state, project) do
    data =
      Map.put(state.data, "projects", [
        project | Enum.reject(state.data["projects"], &(&1["id"] == project["id"]))
      ])

    persist(%{state | data: data})
  end

  defp select(state, client, id),
    do: persist(%{state | data: put_in(state.data, ["selected", selection_key(state, client)], id), error: nil})

  defp available_mods(state, "main") do
    profile = BowserBrain.ModScope.profile_of(state.active)
    BowserBrain.ModCatalog.catalog()
    |> Enum.filter(&(&1.profile == profile))
    |> Enum.map(fn entry ->
      %{path: entry.path, name: Path.basename(BowserBrain.ModCatalog.display(entry.path)),
        scope: entry.host || "Across Bowser", enabled: entry.enabled}
    end)
  end
  defp available_mods(_state, client) do
    if AppMods.valid_id?(client) do
      Path.wildcard(Path.join([AppMods.root(), client, "*.{css,js}{,.off}"]))
      |> Enum.map(fn path ->
        name = Path.basename(path)
        %{path: "app-mods/#{client}/#{name}", name: String.replace_suffix(name, ".off", ""),
          scope: "Only this app", enabled: not String.ends_with?(name, ".off")}
      end)
    else
      []
    end
  end
  defp edit_existing(state, event) do
    client = client(event)
    requested = event["path"]
    entry = Enum.find(available_mods(state, client), fn entry ->
      BowserBrain.ModCatalog.display(entry.path) == BowserBrain.ModCatalog.display(requested || "")
    end)
    if entry do
      path = BowserBrain.ModCatalog.display(entry.path)
      profile = BowserBrain.ModScope.profile_of(state.active)
      existing = Enum.find(state.data["projects"], fn p ->
        (get_in(p, ["app", "id"]) || "main") == client and
          (client != "main" or Map.get(p, "profile", "default") == profile) and
          Enum.any?(paths(p), &(BowserBrain.ModCatalog.display(&1) == path))
      end)
      project = existing ||
        (new_project(entry.name, if(client != "main", do: "app", else: if(entry.scope == "Across Bowser", do: "browser", else: "site")),
          if(client != "main", do: get_in(event, ["app", "url"]) || "", else: if(entry.scope == "Across Bowser", do: "", else: "https://#{entry.scope}")), event["app"])
          |> Map.put("existing_path", path) |> Map.put("profile", profile))
      state |> put_project(project) |> select(client, project["id"])
    else
      %{state | error: "That mod is no longer available in this window."}
    end
  end

  defp action(state, %{"action" => action} = event) do
    client = client(event)
    id = event["project"]
    project = project(state, id)
    valid = project && (get_in(project, ["app", "id"]) || "main") == client &&
      (client != "main" or Map.get(project, "profile", "default") == BowserBrain.ModScope.profile_of(state.active))

    cond do
      action == "open" ->
        %{state | error: nil}

      action == "edit_existing" ->
        edit_existing(state, event)

      action == "new" ->
        select(state, client, nil)

      action == "select" and valid ->
        select(state, client, id)

      action in ["undo", "toggle"] and valid and state.run == nil ->
        revision_action(state, project, action)

      action == "submit" and state.run != nil ->
        %{state | error: "Another change is still running. Your draft has been kept."}

      action == "submit" and id != nil and not valid ->
        %{state | error: "That mod is unavailable in this window."}

      action == "submit" ->
        start(state, event, if(valid, do: project))

      true ->
        state
    end
  end

  def new_project(name, scope, url, app) do
    %{
      "id" => ModRevision.id(),
      "name" => String.slice(name, 0, 70),
      "scope" => scope,
      "url" => url,
      "app" => app,
      "session" => nil,
      "turns" => [],
      "revisions" => [],
      "status" => "ready",
      "summary" => "",
      "notes" => "",
      "checks" => []
    }
  end

  defp start(state, event, existing) do
    text = String.trim(event["text"] || "")
    app = (existing && existing["app"]) || event["app"]

    url =
      (existing && existing["url"]) || (app && app["url"]) || event["url"] ||
        state.urls[state.active] || ""

    if text == "" or (app && not AppMods.valid_id?(app["id"])) do
      state
    else
      scope =
        (existing && existing["scope"]) || if(app, do: "app", else: event["scope"] || "site")

      if scope not in ["browser", "site", "app"] or
           (scope != "browser" and URI.parse(url).host == nil) do
        %{state | error: "Open a website before creating a site mod."}
      else
        p = existing || Map.put(new_project(text, scope, url, app), "profile", BowserBrain.ModScope.profile_of(event["webview"] || state.active))
        revision = ModRevision.new_revision(text)

        p =
          p
          |> Map.put("status", "working")
          |> Map.put("revisions", [revision | p["revisions"]])
          |> Map.put(
            "turns",
            p["turns"] ++ [%{"id" => revision["id"], "role" => "user", "text" => text}]
          )

        state = state |> put_project(p) |> select(client(event), p["id"])
        wv = if app, do: 0, else: target_webview(state, url, event["webview"])
        run = %{token: revision["id"], project: p["id"], webview: wv, profile: BowserBrain.ModScope.profile_of(wv), url: url, app: p["app"]}
        parent = self()

        {pid, ref} =
          spawn_monitor(fn ->
            Process.put(:modsmith_run, run.token)

            result =
              try do
                prompt = prompt(p, text, wv)

                runner =
                  Application.get_env(:bowser_brain, :modsmith_runner, &ModSmith.run_claude/4)

                runner.(
                  prompt,
                  p["session"],
                  fn line -> send(parent, {:progress, run.token, line}) end,
                  p["app"]
                )
              rescue
                error -> {nil, {:error, Exception.message(error)}}
              catch
                :exit, reason -> {nil, {:error, inspect(reason)}}
              end

            {session, output} = result
            send(parent, {:finished, run.token, session, output})
          end)

        %{
          state
          | run: Map.merge(run, %{pid: pid, ref: ref}),
            progress: [],
            error: nil,
            accepted: event["request_id"]
        }
      end
    end
  end

  defp target_webview(state, url, preferred) do
    host = URI.parse(url).host

    cond do
      preferred != nil and URI.parse(state.urls[preferred] || url).host == host ->
        preferred

      URI.parse(state.urls[state.active] || "").host == host ->
        state.active

      true ->
        Enum.find_value(state.urls, state.active, fn {wv, u} ->
          if URI.parse(u).host == host and BowserBrain.ModScope.profile_of(wv) == BowserBrain.ModScope.profile_of(state.active), do: wv
        end)
    end
  end

  defp prompt(p, request, wv) do
    host = URI.parse(p["url"]).host || "unknown"

    catalog =
      if p["app"],
        do: "Only this saved app's CSS/JS is available.",
        else: BowserBrain.ModCatalog.catalog() |> Enum.filter(&(&1.profile == BowserBrain.ModScope.profile_of(wv))) |> Enum.map_join("\n", &("#{&1.path}: #{&1.about}"))

    payloads =
      if p["app"],
        do: AppMods.payloads(p["app"]["id"]),
        else: BowserBrain.SiteMods.payloads_for(host, BowserBrain.ModScope.profile_of(wv))

    base =
      ModSmith.build_prompt(
        request,
        p["url"],
        host,
        ModSmith.page_digest(wv, p["app"]),
        payloads,
        catalog
      )

    base <>
      """

      CORE MODSMITH WORKSPACE CONTRACT (takes precedence):
      The selected mod is #{p["name"]}. Scope is #{p["scope"]}; target URL #{p["url"]}, webview #{wv}.
      #{if p["scope"] == "site", do: "Only this host's payloads or Elixir mods explicitly declaring this host are allowed.", else: ""}
      #{if p["app"], do: "Only CSS/JS for this saved app. Use sites/#{host}/ paths; these are redirected to this app.", else: ""}
      Existing owned files: #{Enum.join(paths(p), ", ")}. #{if p["existing_path"], do: "Modify #{p["existing_path"]} in place.", else: ""}
      You are refining the SAME mod when there is prior conversation. Read the current files before editing: the owner may have undone a revision since your last reply.
      Give the mod a short human-readable "name" in the JSON envelope. Set "status" to "active" when the requested work is delivered, or "partial" for specific unfinished requirements. Usage tips and unperformed optional checks do not by themselves mean partial. Keep "notes" brief and distinguish usage from limitations.
      Add "checks": ["what you actually checked and observed"]. Do not claim checks you did not perform. Use an empty list if none.
      No shell or direct filesystem tools: CSS/JS draft writes go through put_payload;
      Elixir drafts go through put_mod(name: "my_mod.ex", content: full_source), so the owner can undo them.
      For a native shell theme, use put_mod BEFORE checking shell_theme. put_mod returns compilation and startup/reload results; fix reported errors before continuing. Compare the
      returned map to the intended settings. This verifies runtime theme state, not pixels.
      For drafts already installed in this run, return files as [{"path":"mods/example.ex"}] without repeating content. Only unchanged drafts from this run can be referenced. New or changed files still require content. Do not claim the
      installer cannot accept Elixir mods. Saved apps still support only CSS/JS.
      Previous visible conversation: #{JSON.encode!(Enum.take(p["turns"], -12))}
      """
  end

  defp scoped_path(p, path) do
    host = URI.parse(p["url"]).host

    if app = p["app"] do
      case AppMods.filename(path, host, app["id"]) do
        {:ok, name} -> {:ok, "app-mods/#{app["id"]}/#{name}"}
        {:error, reason} -> {:error, reason}
      end
    else
      cond do
        not ModRevision.allowed?(path) ->
          {:error, "Invalid mod file path"}

        String.starts_with?(path, "assets/") ->
          if String.starts_with?(path, "assets/#{p["id"]}/"),
            do: {:ok, path}, else: {:error, "Asset belongs to another mod"}

        String.starts_with?(path, "app-mods/") ->
          {:error, "Saved-app files are outside this mod's scope"}

        p["scope"] == "site" and not String.starts_with?(path, "sites/#{host}/") and
            not String.starts_with?(path, "mods/") ->
          {:error, "File is outside the selected site"}

        true ->
          {:ok, path}
      end
    end
  end

  defp prepare_file(p, %{"path" => path, "content" => content})
       when is_binary(path) and is_binary(content) and byte_size(content) <= 200_000 do
    with {:ok, path} <- scoped_path(p, path), :ok <- validate_code(p, path, content) do
      {:ok, {ModRevision.actual_path(path), content}}
    end
  end

  defp prepare_file(_, _), do: {:error, "Invalid or oversized generated file"}

  defp validate_code(_, "assets/" <> _, content) do
    if String.contains?(content, "<svg") and not Regex.match?(~r/<!DOCTYPE|<!ENTITY|<script|<foreignObject|\b(?:href|src)\s*=\s*["'](?!#)|\burl\s*\(/i, content),
      do: :ok, else: {:error, "Use a self-contained SVG with no scripts, external resources, or entities"}
  end

  defp validate_code(p, path, content) do
    if String.ends_with?(String.replace_suffix(path, ".off", ""), ".ex") do
      with {:ok, ast} <- Code.string_to_quoted(content, static_atoms_encoder: fn name, _ -> {:ok, name} end) do
        host = URI.parse(p["url"]).host
        declarations =
          for {"defmodule", _, [{:__aliases__, _, names}, body]} <- statements(ast),
              is_list(body), Enum.all?(names, &is_binary/1),
              {"use", _, [{:__aliases__, _, target} | arguments]} <- statements(Keyword.get(body, :do)),
              target in [["BowserBrain", "Mod"], ["Elixir", "BowserBrain", "Mod"]],
              do: arguments

        # Only direct declarations describe a mod. Walking into quotes or
        # function bodies mistakes inert examples for executable metadata.
        # This is structural validation, not an Elixir capability boundary.
        cond do
          declarations == [] ->
            {:error, "Generated Elixir must define a top-level module using BowserBrain.Mod"}
          p["scope"] == "site" and not Enum.all?(declarations, fn
            [opts] when is_list(opts) -> List.keyfind(opts, "host", 0) == {"host", host}
            _ -> false
          end) ->
            {:error, "Every site mod must directly declare host: #{host}"}
          true -> :ok
        end
      else
        _ -> {:error, "Generated Elixir has a syntax error"}
      end
    else
      :ok
    end
  end

  defp prepared_files(state, files) do
    p = project(state, state.run.project)
    profile = Map.get(state.run, :profile, BowserBrain.ModScope.profile_of(state.run.webview))
    Enum.map(files, fn file ->
      case prepare_file(p, file) do
        {:ok, {path, content}} = result ->
          if is_nil(p["app"]) and (String.starts_with?(path, "mods/") or String.starts_with?(path, "sites/")) do
            existing = ModRevision.absolute(ModRevision.actual_path(path))
            if File.exists?(existing) and BowserBrain.ModScope.file_profile(existing) != profile do
              {:error, "This file belongs to another profile; choose a different name"}
            else
              {:ok, {path, if(is_binary(content), do: BowserBrain.ModScope.tag(content, profile, Path.extname(String.replace_suffix(path, ".off", ""))), else: content)}}
            end
          else
            result
          end
        error -> error
      end
    end)

  end

  defp audit_key(state, path, content),
    do: {state.run.token, path, BowserBrain.ModAuditor.digest(content)}

  defp audit_gate(state, files, continuation) do
    prepared = prepared_files(state, files)
    with nil <- Enum.find(prepared, &match?({:error, _}, &1)) do
      needed = for {:ok, {path, source}} <- prepared,
        String.ends_with?(String.replace_suffix(path, ".off", ""), ".ex"),
        audit_key(state, path, source) not in Map.get(state, :audit_approvals, []),
        do: {path, source}
      cond do
        needed == [] -> :ready
        Map.get(state, :pending_audit) != nil -> {:error, "A security audit is already running"}
        true ->
          parent = self()
          ref = make_ref()
          token = state.run.token
          p = project(state, state.run.project)
          [revision | _] = p["revisions"]
          context = %{request: revision["request"], scope: p["scope"], host: URI.parse(p["url"]).host}
          pid = spawn(fn ->
            result = Enum.reduce_while(needed, :ok, fn {path, source}, :ok ->
              case BowserBrain.ModAuditor.review(context, path, source) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end
            end)
            send(parent, {:audit_finished, ref, result})
          end)
          timer = Process.send_after(self(), {:audit_finished, ref, {:error, "Security audit timed out; Elixir was not installed"}}, 95_000)
          pending = %{ref: ref, token: token, pid: pid, timer: timer, continuation: continuation,
            keys: Enum.map(needed, fn {path, source} -> audit_key(state, path, source) end)}
          state = state |> Map.put(:pending_audit, pending) |> Map.update!(:progress, &(&1 ++ ["Security audit reviewing generated Elixir"]))
          publish(state)
          {:pending, state}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, "Cannot prepare generated files for security audit"}
  end

  defp write_files(state, files) do
    prepared = prepared_files(state, files)
    prepared = Enum.map(prepared, fn
      {:ok, {path, source}} = item ->
        if String.ends_with?(String.replace_suffix(path, ".off", ""), ".ex") and
             audit_key(state, path, source) not in Map.get(state, :audit_approvals, []),
          do: {:error, "Security audit approval is required before installing Elixir"}, else: item
      item -> item
    end)

    case Enum.find(prepared, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason, state}

      nil ->
        Enum.reduce_while(prepared, {:ok, state}, fn {:ok, {path, content}}, {:ok, current} ->
          captured =
            try do
              p = project(current, current.run.project)
              [revision | rest] = p["revisions"]
              revision = ModRevision.capture(revision, path, content)
              {:ok, put_project(current, Map.put(p, "revisions", [revision | rest]))}
            rescue
              error -> {:error, Exception.message(error)}
            end

          case captured do
            {:error, reason} ->
              {:halt, {:error, reason, current}}

            {:ok, recorded} ->
              try do
                ModRevision.write(path, content)
                {:cont, {:ok, recorded}}
              rescue
                error -> {:halt, {:error, Exception.message(error), recorded}}
              end
          end
        end)
    end
  rescue
    error -> {:error, Exception.message(error), state}
  end

  # References may only name an unchanged draft captured by THIS run.
  defp resolve_drafts(state, files) when is_list(files) do
    [revision | _] = project(state, state.run.project)["revisions"]
    Enum.map(files, fn
      %{"path" => path} = file when not is_map_key(file, "content") ->
        case revision["files"][path] do
          %{"after" => content} when is_binary(content) ->
            if ModRevision.read(path) == content, do: Map.put(file, "content", content), else: file
          _ -> file
        end
      file -> file
    end)
  end
  defp resolve_drafts(_, files), do: files

  defp finish(state, session, result) do
    Process.demonitor(state.run.ref, [:flush])

    {state, status, summary, notes, checks, name} =
      case result do
        {:output, output} ->
          case ModSmith.extract_json(output) do
            {:ok, envelope} when is_map(envelope) ->
              files = envelope["files"] || []
              files = resolve_drafts(state, files)
              notes = string(envelope["notes"])
              summary = string(envelope["summary"])

              checks =
                if is_list(envelope["checks"]),
                  do: Enum.filter(envelope["checks"], &is_binary/1),
                  else: []

              cond do
                files == [] ->
                  {state, "needs_help", summary, notes, checks, envelope["name"]}

                not is_list(files) ->
                  {state, "failed", "Invalid generated file list", notes, checks, nil}

                true ->
                  case write_files(state, files) do
                    {:ok, state} ->
                      {state, if(envelope["status"] == "partial", do: "partial", else: "active"), summary, notes,
                       checks, envelope["name"]}

                    {:error, reason, state} ->
                      {state, "failed", reason, notes, checks, nil}
                  end
              end

            _ ->
              {state, "failed", "The agent did not return a usable result.", "", [], nil}
          end

        {:error, reason} ->
          {state, "failed", string(reason), "", [], nil}
      end

    p = project(state, state.run.project)
    [revision | rest] = p["revisions"]
    revision = revision |> Map.put("status", status) |> Map.put("summary", summary)

    turn = %{
      "id" => ModRevision.id(),
      "role" => "assistant",
      "text" => summary,
      "status" => status,
      "notes" => notes,
      "checks" => checks
    }

    p =
      p
      |> Map.put("session", session || p["session"])
      |> Map.put("status", status)
      |> Map.put("summary", summary)
      |> Map.put("notes", notes)
      |> Map.put("checks", checks)
      |> Map.put("revisions", [revision | rest])
      |> Map.put("turns", p["turns"] ++ [turn])
      |> Map.put(
        "name",
        if(is_binary(name) and name != "", do: String.slice(name, 0, 70), else: p["name"])
      )

    state = put_project(state, p)
    %{state | run: nil} |> Map.put(:audit_approvals, [])
  end

  defp string(value) when is_binary(value), do: value
  defp string(nil), do: ""
  defp string(value), do: JSON.encode!(value)

  defp paths(p),
    do:
      (Enum.flat_map(p["revisions"], &Map.keys(&1["files"])) ++ List.wrap(p["existing_path"]))
      |> Enum.uniq()

  defp live_paths(p) do
    paths(p)
    |> Enum.flat_map(fn path ->
      plain = String.replace_suffix(path, ".off", "")
      [plain, plain <> ".off"]
    end)
    |> Enum.uniq()
    |> Enum.filter(&(ModRevision.read(&1) != nil))
  end

  defp revision_action(state, p, "undo") do
    revision = Enum.find(p["revisions"], &(&1["status"] != "undone" and ModRevision.changed?(&1)))

    if revision do
      state = put_project(state, Map.put(p, "pending_undo", revision["id"]))

      case ModRevision.restore(revision) do
        :ok ->
          revisions =
            Enum.map(p["revisions"], fn r ->
              if r["id"] == revision["id"], do: Map.put(r, "status", "undone"), else: r
            end)

          p =
            p
            |> Map.put("revisions", revisions)
            |> Map.put("status", "restored")
            |> Map.put("summary", "Restored the files from before: #{revision["request"]}")
            |> Map.put("session", nil)
            |> Map.put(
              "turns",
              p["turns"] ++
                [
                  %{
                    "id" => ModRevision.id(),
                    "role" => "system",
                    "text" =>
                      "Undid: #{revision["request"]}. Website actions and stored mod data were not reversed."
                  }
                ]
            )

          put_project(%{state | error: nil}, p)

        {:error, reason} ->
          state = put_project(state, p)
          %{state | error: reason}
      end
    else
      state
    end
  end

  defp revision_action(state, p, "toggle") do
    files = live_paths(p)
    enabled = Enum.any?(files, &(not String.ends_with?(&1, ".off")))
    files = Enum.filter(files, &(String.ends_with?(&1, ".off") != enabled))
    revision = ModRevision.new_revision(if(enabled, do: "Disable mod", else: "Enable mod"))

    pairs =
      Enum.flat_map(files, fn path ->
        target = if enabled, do: path <> ".off", else: String.replace_suffix(path, ".off", "")

        if ModRevision.read(target) != nil,
          do: raise("Both active and disabled files exist; resolve them before toggling.")

        [{target, ModRevision.read(path)}, {path, nil}]
      end)

    revision =
      Enum.reduce(pairs, revision, fn {path, content}, r ->
        ModRevision.capture(r, path, content)
      end)

    p = Map.put(p, "revisions", [revision | p["revisions"]])
    state = put_project(state, p)

    result =
      try do
        Enum.each(pairs, fn {path, content} -> ModRevision.write(path, content) end)
        :ok
      rescue
        error -> {:error, Exception.message(error)}
      end

    status =
      if result == :ok, do: if(enabled, do: "disabled", else: "active"), else: "interrupted"

    p =
      p
      |> Map.put("status", status)
      |> Map.put("revisions", [Map.put(revision, "status", status) | tl(p["revisions"])])

    state = put_project(state, p)

    case result do
      :ok -> %{state | error: nil}
      {:error, reason} -> %{state | error: "#{reason}. Use Undo to restore the files."}
    end
  end

  def snapshot(state, client) do
    projects =
      Enum.filter(state.data["projects"], &((get_in(&1, ["app", "id"]) || "main") == client and
        (client != "main" or Map.get(&1, "profile", "default") == BowserBrain.ModScope.profile_of(state.active))))

    %{
      op: "modsmith_state",
      available_mods: available_mods(state, client),
      app: if(client == "main", do: nil, else: client),
      selected: selected(state, client),
      busy: state.run != nil,
      accepted: state.accepted,
      error: if(Map.get(state, :error_client, "main") == client, do: state.error),
      progress:
        if(state.run && (get_in(state.run.app || %{}, ["id"]) || "main") == client,
          do: state.progress,
          else: []
        ),
      stage: stage(state.progress),
      projects:
        Enum.map(projects, fn p ->
          files = live_paths(p)

          revision =
            Enum.find(p["revisions"], &(&1["status"] != "undone" and ModRevision.changed?(&1)))

          p
          |> Map.drop(["session", "revisions"])
          |> Map.put("files", files)
          |> Map.put("enabled", Enum.any?(files, &(not String.ends_with?(&1, ".off"))))
          |> Map.put("can_undo", revision != nil)
          |> Map.put("undo_label", revision && revision["request"])
        end)
    }
  end

  def stage(progress) do
    line = List.last(progress) || ""

    cond do
      String.contains?(line, ["put_payload", "store_put"]) -> "Making changes"
      String.contains?(line, "page_eval") -> "Checking the page"
      true -> "Inspecting and building"
    end
  end

  defp publish(state, client \\ nil, show \\ false) do
    clients =
      if client, do: [client], else: Enum.uniq(["main" | Map.keys(state.data["selected"])])

    Enum.each(clients, fn c -> Bridge.cast_msg(Map.put(snapshot(state, c), :show, show)) end)
  end
end
