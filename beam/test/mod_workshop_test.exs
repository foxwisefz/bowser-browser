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

  test "Elixir drafts share final revision history and Undo removes the installed file" do
    event("submit", %{"text" => "AOL shell", "scope" => "browser"})
    assert_receive {:runner, pid, token, prompt, nil, nil}, 1000
    assert prompt =~ "put_mod"
    content = "defmodule DraftSkin do\n use BowserBrain.Mod\nend"
    assert %{ok: true, installed: "mods/draft_skin.ex"} =
      ModWorkshop.tool(token, "put_mod", %{"name" => "draft_skin.ex", "content" => content})
    assert ModRevision.read("mods/draft_skin.ex") == content
    state = complete(pid, [%{"path" => "mods/draft_skin.ex"}], %{"notes" => "Use the toolbar."})
    assert hd(state.data["projects"])["status"] == "active"
    [project] = state.data["projects"]
    assert hd(project["revisions"])["files"]["mods/draft_skin.ex"]["before"] == nil
    assert %{ok: false} = ModWorkshop.tool(token, "put_mod", %{"name" => "late.ex", "content" => content})
    event("undo", %{"project" => project["id"]})
    assert ModRevision.read("mods/draft_skin.ex") == nil
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
    assert ModRevision.read("sites/example.com/reading.css") == "second"
    assert hd(state.data["projects"])["session"] == nil
    event("undo", %{"project" => id})
    assert ModRevision.read("sites/example.com/reading.css") == "first"
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
    assert ModRevision.read("sites/example.com/reading.css") == "draft"
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
    assert ModRevision.read("sites/example.com/reading.css.off") == "one"
    event("submit", %{"project" => p["id"], "text" => "Change while disabled"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    complete(pid, [file("two")])
    assert ModRevision.read("sites/example.com/reading.css") == nil
    assert ModRevision.read("sites/example.com/reading.css.off") == "two"
    event("undo", %{"project" => p["id"]})
    event("undo", %{"project" => p["id"]})
    assert ModRevision.read("sites/example.com/reading.css") == "one"
    assert ModRevision.read("sites/example.com/reading.css.off") == nil
  end

  test "saved app has its own history, revisions and CSS/JS scope" do
    app = %{"id" => "com.gezim.bowser.site.0123456789abcdef", "url" => "https://example.com"}
    event("submit", %{"app" => app, "text" => "App reading mode"})
    assert_receive {:runner, pid, token, _, nil, ^app}, 1000

    assert %{ok: false} = ModWorkshop.tool(token, "put_mod", %{
      "name" => "app.ex", "content" => "defmodule AppDraft do use BowserBrain.Mod end"
    })
    assert ModRevision.read("mods/app.ex") == nil

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

  test "pending undo finishes after restart, and legacy conversations migrate once", %{root: root} do
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

    old_path = Application.get_env(:bowser_brain, :modsmith_sessions_path)
    path = Path.join(root, "legacy.json")

    File.write!(
      path,
      JSON.encode!([
        %{id: "legacy-session", host: "example.com", request: "Read", summary: "Reading"}
      ])
    )

    Application.put_env(:bowser_brain, :modsmith_sessions_path, path)

    try do
      migrated = ModWorkshop.migrate_sessions(ModRevision.empty())
      assert hd(migrated["projects"])["session"] == "legacy-session"
      assert ModWorkshop.migrate_sessions(migrated) == migrated
      assert File.read!(path) =~ "legacy-session"
    after
      Application.put_env(:bowser_brain, :modsmith_sessions_path, old_path)
    end
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
           ] == "draft"
  end

  test "invalid later file prevents final envelope writes, and saved apps reject modules" do
    event("submit", %{"text" => "Reading mode"})
    assert_receive {:runner, pid, _, _, _, _}, 1000

    state =
      complete(pid, [file("good"), %{"path" => "sites/other.com/bad.css", "content" => "bad"}])

    assert hd(state.data["projects"])["status"] == "failed"
    assert ModRevision.read("sites/example.com/reading.css") == nil
    app = %{"id" => "com.gezim.bowser.site.0123456789abcdef", "url" => "https://example.com"}
    event("submit", %{"app" => app, "text" => "App mod"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    state = complete(pid, [%{"path" => "mods/global.ex", "content" => "defmodule Demo do end"}])
    assert hd(state.data["projects"])["status"] == "failed"
    assert ModRevision.read("mods/global.ex") == nil
  end
end
