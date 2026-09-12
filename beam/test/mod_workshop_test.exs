defmodule BowserBrain.ModWorkshopTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{ModWorkshop, ModRevision}

  setup do
    root = Path.join(System.tmp_dir!(), "modsmith-#{ModRevision.id()}")
    File.mkdir_p!(root)
    old_home = System.get_env("BOWSER_HOME")
    old_path = Application.get_env(:bowser_brain, :modsmith_workspace_path)
    original = :sys.get_state(ModWorkshop)
    System.put_env("BOWSER_HOME", root)
    Application.put_env(:bowser_brain, :modsmith_workspace_path, Path.join(root, "history.json"))

    :sys.replace_state(ModWorkshop, fn _ ->
      %{
        original
        | data: ModRevision.empty(),
          run: nil,
          error: nil,
          urls: %{7 => "https://example.com"},
          active: 7
      }
    end)

    owner = self()

    Application.put_env(:bowser_brain, :modsmith_runner, fn prompt, resume, _, app ->
      send(owner, {:runner, self(), Process.get(:modsmith_run), prompt, resume, app})

      receive do
        {:result, result} -> result
      end
    end)

    on_exit(fn ->
      state = :sys.get_state(ModWorkshop)
      if state.run, do: Process.exit(state.run.pid, :kill)
      :sys.replace_state(ModWorkshop, fn _ -> original end)

      if old_home,
        do: System.put_env("BOWSER_HOME", old_home),
        else: System.delete_env("BOWSER_HOME")

      Application.put_env(:bowser_brain, :modsmith_workspace_path, old_path)
      Application.delete_env(:bowser_brain, :modsmith_runner)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "existing disabled mods reopen one conversation and reject foreign paths", %{root: root} do
    File.mkdir_p!(Path.join(root, "mods"))
    File.write!(Path.join(root, "mods/reader.ex.off"), "# Existing reader\n")
    File.write!(Path.join(root, "mods/other.ex"), "# bowser-profile: other\n")
    state = event("open", %{})
    available = ModWorkshop.snapshot(state, "main").available_mods
    assert Enum.any?(available, &(&1.path == "mods/reader.ex.off" and not &1.enabled))
    refute Enum.any?(available, &(&1.path == "mods/other.ex"))
    state = event("edit_existing", %{"path" => "mods/reader.ex.off"})
    [project] = state.data["projects"]
    assert project["existing_path"] == "mods/reader.ex"
    assert project["status"] == "ready"
    state = event("edit_existing", %{"path" => "mods/reader.ex"})
    assert length(state.data["projects"]) == 1
    assert ModWorkshop.snapshot(state, "main").selected == project["id"]
    state = event("edit_existing", %{"path" => "mods/other.ex"})
    assert state.error != nil
    state = event("edit_existing", %{"path" => "../private"})
    assert state.error != nil
    assert length(state.data["projects"]) == 1
  end

  test "saved-app picker includes disabled files only from its own app", %{root: root} do
    id = "com.foxwiseai.bowser.site.0123456789abcdef"
    app = %{"id" => id, "url" => "https://example.com", "name" => "Example"}
    dir = Path.join([root, "app-mods", id])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "reader.css.off"), "body { color: red }")
    state = event("open", %{"app" => app})
    assert [%{path: path, enabled: false}] = ModWorkshop.snapshot(state, id).available_mods
    state = event("edit_existing", %{"app" => app, "path" => path})
    [project] = state.data["projects"]
    assert project["scope"] == "app"
    assert project["app"] == app
    assert ModWorkshop.snapshot(state, "main").projects == []
  end

  defp event(action, values) do
    send(
      ModWorkshop,
      {:browser_event, Map.merge(%{"event" => "modsmith", "action" => action}, values)}
    )

    :sys.get_state(ModWorkshop)
  end

  defp complete(pid, files, extra \\ %{}) do
    envelope =
      Map.merge(
        %{
          "files" => files,
          "name" => "Reading mode",
          "summary" => "Made the text larger",
          "notes" => "",
          "checks" => ["Checked computed font size"]
        },
        extra
      )

    send(pid, {:result, {"session-1", {:output, JSON.encode!(envelope)}}})
    await(fn -> :sys.get_state(ModWorkshop).run == nil end)
    :sys.get_state(ModWorkshop)
  end

  defp await(fun, attempts \\ 200)
  defp await(_, 0), do: flunk("workflow did not settle")

  defp await(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          await(fun, attempts - 1)
        )
  end

  defp file(content), do: %{"path" => "sites/example.com/reading.css", "content" => content}

test "Work drafts and project lists cannot take over Default mods" do
  session = :sys.get_state(BowserBrain.Session)
  :sys.replace_state(BowserBrain.Session, &Map.put(&1, :profiles, %{7 => "work"}))
  on_exit(fn -> :sys.replace_state(BowserBrain.Session, fn _ -> session end) end)
  ModRevision.write("mods/owned.ex", "defmodule DefaultOwned do use BowserBrain.Mod end")
  event("submit", %{"text" => "Work shell", "scope" => "browser"})
  assert_receive {:runner, _pid, token, _, nil, nil}, 1000
  assert %{ok: false} = ModWorkshop.tool(token, "put_mod", %{"name" => "owned.ex", "content" => "defmodule DefaultOwned do use BowserBrain.Mod end"})
  assert BowserBrain.ModScope.file_profile(ModRevision.absolute("mods/owned.ex")) == "default"
  state = :sys.get_state(ModWorkshop)
  [work] = state.data["projects"]
  assert work["profile"] == "work"
  default = ModWorkshop.new_project("Default only", "browser", "https://example.com", nil)
  state = put_in(state.data["projects"], [default, work])
  assert Enum.map(ModWorkshop.snapshot(state, "main").projects, & &1["id"]) == [work["id"]]
  assert ModWorkshop.snapshot(state, "main").selected == work["id"]
end

  test "source and Store tools enforce profile ownership on every operation", %{root: root} do
    session = :sys.get_state(BowserBrain.Session)
    :sys.replace_state(BowserBrain.Session, &Map.put(&1, :profiles, %{7 => "default"}))
    on_exit(fn -> :sys.replace_state(BowserBrain.Session, fn _ -> session end) end)
    suffix = Base.encode16(:crypto.strong_rand_bytes(8))
    mine = "DefaultStore" <> suffix
    foreign = "WorkStore" <> suffix
    fake = "QuotedStore" <> suffix
    for {file, profile, name} <- [{"mine.ex.off", "default", mine}, {"foreign.ex", "work", foreign}] do
      ModRevision.write("mods/" <> file,
        "# bowser-profile: #{profile}\ndefmodule #{name} do use BowserBrain.Mod end")
    end
    ModRevision.write("mods/quote.ex", "quote do defmodule #{fake} do use BowserBrain.Mod end end")
    ModRevision.write("sites/example.com/private.css.off", "/* bowser-profile: work */\nbody {}")
    BowserBrain.Store.put(foreign, "secret", "original")
    on_exit(fn ->
      BowserBrain.Store.clear(mine)
      BowserBrain.Store.clear(foreign)
    end)
    event("submit", %{"text" => "Fix my mod", "scope" => "browser"})
    assert_receive {:runner, _pid, token, _, nil, nil}, 1000
    assert %{ok: true, content: source} = ModWorkshop.tool(token, "read_mod", %{"path" => "mods/mine.ex"})
    assert source =~ mine
    for path <- ["mods/foreign.ex", "sites/example.com/private.css", "mods/missing.ex", "../settings.json", nil] do
      assert %{ok: false} = ModWorkshop.tool(token, "read_mod", %{"path" => path})
    end
    for name <- [foreign, "Elixir." <> foreign, fake, "Unknown", "../" <> mine, nil] do
      assert %{ok: false} = ModWorkshop.tool(token, "store_get", %{"mod" => name})
      assert %{ok: false} = ModWorkshop.tool(token, "store_put", %{"mod" => name, "key" => "secret", "value" => "changed"})
    end
    assert BowserBrain.Store.get(foreign, "secret") == "original"
    assert %{ok: true} = ModWorkshop.tool(token, "store_put", %{"mod" => "Elixir." <> mine, "key" => "draft", "value" => "mine"})
    assert %{ok: true, value: "mine"} = ModWorkshop.tool(token, "store_get", %{"mod" => mine, "key" => "draft"})

    # Source ownership is rechecked rather than cached from list_mods or a
    # previous successful request. Conflicting profiles cannot share Store.
    ModRevision.write("mods/conflict.ex", "# bowser-profile: work\ndefmodule #{mine} do use BowserBrain.Mod end")
    assert %{ok: false} = ModWorkshop.tool(token, "store_get", %{"mod" => mine})
    File.rm!(Path.join(root, "mods/conflict.ex"))
    File.rename!(Path.join(root, "mods/mine.ex.off"), Path.join(root, "outside.ex"))
    File.ln_s!(Path.join(root, "outside.ex"), Path.join(root, "mods/mine.ex.off"))
    assert %{ok: false} = ModWorkshop.tool(token, "read_mod", %{"path" => "mods/mine.ex"})
    assert %{ok: false} = ModWorkshop.tool(token, "store_get", %{"mod" => mine})
  end


  test "Elixir drafts share final revision history and Undo removes the installed file" do
    event("submit", %{"text" => "AOL shell", "scope" => "browser"})
    assert_receive {:runner, pid, token, prompt, nil, nil}, 1000
    assert prompt =~ "put_mod"
    content = "defmodule DraftSkin do\n use BowserBrain.Mod\nend"
    assert %{ok: true, installed: "mods/draft_skin.ex"} =
      ModWorkshop.tool(token, "put_mod", %{"name" => "draft_skin.ex", "content" => content})
    assert ModRevision.read("mods/draft_skin.ex") == BowserBrain.ModScope.tag(content, "default")
    state = complete(pid, [%{"path" => "mods/draft_skin.ex"}], %{"notes" => "Use the toolbar."})
    assert hd(state.data["projects"])["status"] == "active"
    [project] = state.data["projects"]
    assert hd(project["revisions"])["files"]["mods/draft_skin.ex"]["before"] == nil
    assert %{ok: false} = ModWorkshop.tool(token, "put_mod", %{"name" => "late.ex", "content" => content})
    event("undo", %{"project" => project["id"]})
    assert ModRevision.read("mods/draft_skin.ex") == nil
    for {mod_pid, _} <- Registry.lookup(BowserBrain.ModRegistry, DraftSkin),
      do: DynamicSupervisor.terminate_child(BowserBrain.ModSupervisor, mod_pid)
  end

  test "draft reports init failures without losing Undo history" do
    event("submit", %{"text" => "AOL shell", "scope" => "browser"})
    assert_receive {:runner, pid, token, _, nil, nil}, 1000
    source = "defmodule BrokenDraftInit do use BowserBrain.Mod; def init_mod(_), do: raise(\"broken init\") end"
    assert %{ok: false, runtime: %{modules: [%{status: "failed", error: error}]}} =
      ModWorkshop.tool(token, "put_mod", %{"name" => "broken_init.ex", "content" => source})
    assert error =~ "broken init"
    complete(pid, [])
  end

  test "SVG assets belong to the current mod and are removed by Undo" do
    event("submit", %{"text" => "AOL logo", "scope" => "browser"})
    assert_receive {:runner, pid, token, _, nil, nil}, 1000
    svg = ~s(<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" fill="red"/></svg>)
    assert %{ok: true, installed: path, image_path: absolute} =
      ModWorkshop.tool(token, "put_asset", %{"name" => "logo.svg", "content" => svg})
    assert File.read!(absolute) == svg
    assert %{ok: false} = ModWorkshop.tool(token, "put_asset", %{"name" => "../logo.svg", "content" => svg})
    assert %{ok: false} = ModWorkshop.tool(token, "put_asset", %{"name" => "bad.svg", "content" => "<svg><script/></svg>"})
    state = complete(pid, [%{"path" => path}])
    [p] = state.data["projects"]
    assert p["status"] == "active"
    event("undo", %{"project" => p["id"]})
    refute File.exists?(absolute)
  end

  test "Elixir draft rejects paths, syntax errors, and unscoped code for site requests" do
    event("submit", %{"text" => "Style this site", "scope" => "site"})
    assert_receive {:runner, pid, token, _, nil, nil}, 1000
    for args <- [
      %{"name" => "../escape.ex", "content" => "defmodule Escape do end"},
      %{"name" => "invalid.ex", "content" => "defmodule Broken do"},
      %{"name" => "unscoped.ex", "content" => "defmodule Unscoped do use BowserBrain.Mod end"}
    ] do
      assert %{ok: false} = ModWorkshop.tool(token, "put_mod", args)
    end
    assert ModRevision.read("mods/unscoped.ex") == nil
    complete(pid, [])
  end

  test "draft and final share an original snapshot; repeated refinements and undo retain identity" do
    ModRevision.write("sites/example.com/reading.css", "original")
    event("submit", %{"text" => "Bigger text", "request_id" => "request-1"})
    assert_receive {:runner, pid, token, _, nil, nil}, 1000

    assert %{ok: true} =
             ModWorkshop.tool(token, "put_payload", %{
               "host" => "example.com",
               "name" => "reading.css",
               "content" => "draft"
             })

    state = complete(pid, [file("first")])
    [p] = state.data["projects"]
    id = p["id"]
    assert state.data["selected"]["main"] == id
    assert hd(p["revisions"])["files"]["sites/example.com/reading.css"]["before"] == "original"
    assert state.accepted == "request-1"

    for content <- ["second", "third"] do
      event("submit", %{"project" => id, "text" => "Even bigger"})
      assert_receive {:runner, pid, _, prompt, "session-1", nil}, 1000
      assert prompt =~ "Reading mode"
      complete(pid, [file(content)])
    end

    state = event("undo", %{"project" => id})
    assert ModRevision.read("sites/example.com/reading.css") == BowserBrain.ModScope.tag("second", "default", ".css")
    assert hd(state.data["projects"])["session"] == nil
    event("undo", %{"project" => id})
    assert ModRevision.read("sites/example.com/reading.css") == BowserBrain.ModScope.tag("first", "default", ".css")
    event("undo", %{"project" => id})
    assert ModRevision.read("sites/example.com/reading.css") == "original"
    assert ModRevision.load()["selected"]["main"] == id
  end

  test "failure retains draft with undo, rejects late tool calls, and surfaces caveats" do
    event("submit", %{"text" => "Reading mode"})
    assert_receive {:runner, pid, token, _, _, _}, 1000

    assert %{ok: true} =
             ModWorkshop.tool(token, "put_payload", %{
               "host" => "example.com",
               "name" => "reading.css",
               "content" => "draft"
             })

    send(pid, {:result, {"failed-session", {:error, "Timed out"}}})
    await(fn -> :sys.get_state(ModWorkshop).run == nil end)
    [p] = :sys.get_state(ModWorkshop).data["projects"]
    assert p["status"] == "failed"
    assert ModRevision.read("sites/example.com/reading.css") == BowserBrain.ModScope.tag("draft", "default", ".css")
    assert %{ok: false} = ModWorkshop.tool(token, "put_payload", %{})
    event("undo", %{"project" => p["id"]})
    assert ModRevision.read("sites/example.com/reading.css") == nil
    event("submit", %{"project" => p["id"], "text" => "Try again"})
    assert_receive {:runner, pid, _, _, _, _}, 1000

    state =
      complete(pid, [file("working")], %{"status" => "partial", "notes" => "Mobile layout is unfinished", "checks" => []})

    [p] = state.data["projects"]
    assert p["status"] == "partial"
    assert List.last(p["turns"])["notes"] == "Mobile layout is unfinished"
    assert List.last(p["turns"])["checks"] == []
  end

  test "tab changes do not retarget a refinement; off-site writes are refused" do
    event("submit", %{"text" => "Reading mode"})
    assert_receive {:runner, pid, token, _, _, _}, 1000

    assert %{ok: false} =
             ModWorkshop.tool(token, "put_payload", %{
               "host" => "other.com",
               "name" => "reading.css",
               "content" => "bad"
             })

    state = complete(pid, [file("one")])
    [p] = state.data["projects"]

    send(
      ModWorkshop,
      {:browser_event, %{"event" => "url_changed", "webview" => 8, "url" => "https://other.com"}}
    )

    send(ModWorkshop, {:browser_event, %{"event" => "tab_activated", "webview" => 8}})
    event("submit", %{"project" => p["id"], "text" => "Refine"})
    assert_receive {:runner, pid, token, prompt, _, _}, 1000
    assert prompt =~ "webview 7"
    assert %{active: 7} = ModWorkshop.tool(token, "list_tabs", %{})
    complete(pid, [file("two")])
  end

  test "undo preflights every file and preserves an external edit" do
    r =
      ModRevision.new_revision("two files")
      |> ModRevision.capture("sites/example.com/a.css", "a")
      |> ModRevision.capture("sites/example.com/b.css", "b")

    ModRevision.write("sites/example.com/a.css", "a")
    ModRevision.write("sites/example.com/b.css", "external")
    assert {:error, _} = ModRevision.restore(r)
    assert ModRevision.read("sites/example.com/a.css") == "a"
    assert ModRevision.read("sites/example.com/b.css") == "external"
  end

  test "toggle is reversible and editing disabled files leaves them disabled" do
    event("submit", %{"text" => "Reading mode"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    state = complete(pid, [file("one")])
    [p] = state.data["projects"]
    event("toggle", %{"project" => p["id"]})
    assert ModRevision.read("sites/example.com/reading.css") == nil
    assert ModRevision.read("sites/example.com/reading.css.off") == BowserBrain.ModScope.tag("one", "default", ".css")
    event("submit", %{"project" => p["id"], "text" => "Change while disabled"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    complete(pid, [file("two")])
    assert ModRevision.read("sites/example.com/reading.css") == nil
    assert ModRevision.read("sites/example.com/reading.css.off") == BowserBrain.ModScope.tag("two", "default", ".css")
    event("undo", %{"project" => p["id"]})
    event("undo", %{"project" => p["id"]})
    assert ModRevision.read("sites/example.com/reading.css") == BowserBrain.ModScope.tag("one", "default", ".css")
    assert ModRevision.read("sites/example.com/reading.css.off") == nil
  end

  test "saved app has its own history, revisions and CSS/JS scope" do
    app = %{"id" => "com.foxwiseai.bowser.site.0123456789abcdef", "url" => "https://example.com"}
    event("submit", %{"app" => app, "text" => "App reading mode"})
    assert_receive {:runner, pid, token, _, nil, ^app}, 1000

    assert %{ok: false} = ModWorkshop.tool(token, "put_mod", %{
      "name" => "app.ex", "content" => "defmodule AppDraft do use BowserBrain.Mod end"
    })
    assert ModRevision.read("mods/app.ex") == nil
    for tool <- ["store_get", "store_put"] do
      assert %{ok: false} = ModWorkshop.tool(token, tool, %{"mod" => "AnyMod", "key" => "secret", "value" => "changed"})
    end
    assert %{ok: false} = ModWorkshop.tool(token, "read_mod", %{"path" => "mods/app.ex", "site_app" => "main"})

    assert %{ok: true} =
             ModWorkshop.tool(token, "put_payload", %{
               "name" => "reading.css",
               "content" => "app draft"
             })

    state = complete(pid, [file("app final")])
    assert ModRevision.read("sites/example.com/reading.css") == nil
    assert ModRevision.read("app-mods/#{app["id"]}/reading.css") == "app final"
    assert ModWorkshop.snapshot(state, "main").projects == []
    [p] = ModWorkshop.snapshot(state, app["id"]).projects
    event("undo", %{"app" => app, "project" => p["id"]})
    assert ModRevision.read("app-mods/#{app["id"]}/reading.css") == nil
  end

  test "interrupted run reopens as recoverable and keeps selected conversation" do
    p = ModWorkshop.new_project("Reading", "site", "https://example.com", nil)

    r =
      ModRevision.new_revision("draft")
      |> ModRevision.capture("sites/example.com/reading.css", "draft")

    p = Map.merge(p, %{"status" => "working", "revisions" => [r]})
    ModRevision.write("sites/example.com/reading.css", "draft")
    data = ModWorkshop.recover(%{"projects" => [p], "selected" => %{"main" => p["id"]}})
    assert hd(data["projects"])["status"] == "interrupted"
    assert data["selected"]["main"] == p["id"]
    assert :ok = ModRevision.restore(hd(hd(data["projects"])["revisions"]))
  end

  test "symlinked mod directories cannot escape the revision root", %{root: root} do
    File.mkdir_p!(Path.join(root, "sites"))
    File.ln_s!(System.tmp_dir!(), Path.join(root, "sites/example.com"))
    assert_raise ArgumentError, fn -> ModRevision.write("sites/example.com/a.css", "bad") end
    refute ModRevision.allowed?("sites/example.com/../../a.css")
  end

  test "pending undo finishes after restart" do
    p = ModWorkshop.new_project("Reading", "site", "https://example.com", nil)

    r =
      ModRevision.new_revision("new file")
      |> ModRevision.capture("sites/example.com/reading.css", "draft")
      |> Map.put("status", "active")

    ModRevision.write("sites/example.com/reading.css", "draft")
    p = Map.merge(p, %{"status" => "active", "revisions" => [r], "pending_undo" => r["id"]})
    data = ModWorkshop.recover(%{"projects" => [p], "selected" => %{"main" => p["id"]}})
    assert ModRevision.read("sites/example.com/reading.css") == nil
    assert hd(hd(data["projects"])["revisions"])["status"] == "undone"
    assert hd(data["projects"])["pending_undo"] == nil

  end

  test "final output cannot overwrite an external edit made after a draft" do
    event("submit", %{"text" => "Reading mode"})
    assert_receive {:runner, pid, token, _, _, _}, 1000

    assert %{ok: true} =
             ModWorkshop.tool(token, "put_payload", %{
               "host" => "example.com",
               "name" => "reading.css",
               "content" => "draft"
             })

    ModRevision.write("sites/example.com/reading.css", "owner edit")
    state = complete(pid, [file("final")])
    assert hd(state.data["projects"])["status"] == "failed"
    assert ModRevision.read("sites/example.com/reading.css") == "owner edit"

    assert hd(hd(state.data["projects"])["revisions"])["files"]["sites/example.com/reading.css"][
             "after"
           ] == BowserBrain.ModScope.tag("draft", "default", ".css")
  end

  test "invalid later file prevents final envelope writes, and saved apps reject modules" do
    event("submit", %{"text" => "Reading mode"})
    assert_receive {:runner, pid, _, _, _, _}, 1000

    state =
      complete(pid, [file("good"), %{"path" => "sites/other.com/bad.css", "content" => "bad"}])

    assert hd(state.data["projects"])["status"] == "failed"
    assert ModRevision.read("sites/example.com/reading.css") == nil
    app = %{"id" => "com.foxwiseai.bowser.site.0123456789abcdef", "url" => "https://example.com"}
    event("submit", %{"app" => app, "text" => "App mod"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    state = complete(pid, [%{"path" => "mods/global.ex", "content" => "defmodule Demo do end"}])
    assert hd(state.data["projects"])["status"] == "failed"
    assert ModRevision.read("mods/global.ex") == nil
  end
end
