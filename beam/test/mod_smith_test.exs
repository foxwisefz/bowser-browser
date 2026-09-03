defmodule BowserBrain.ModSmithTest do
  use ExUnit.Case, async: true

  alias BowserBrain.ModSmith

  describe "extract_json/1" do
    test "parses a clean envelope" do
      out = ~s({"tier":"payload","summary":"x","files":[]})
      assert {:ok, %{"tier" => "payload"}} = ModSmith.extract_json(out)
    end

    test "parses an envelope wrapped in prose and fences" do
      out = "Sure! Here you go:\n```json\n{\"summary\":\"s\",\"files\":[]}\n```\nDone."
      assert {:ok, %{"summary" => "s"}} = ModSmith.extract_json(out)
    end

    test "rejects output with no JSON" do
      assert {:error, _} = ModSmith.extract_json("I cannot do that.")
    end
  end

  describe "validate/1" do
    test "accepts payload paths" do
      assert :ok =
               ModSmith.validate([
                 %{"path" => "sites/x.com/a.css", "content" => "body{}"}
               ])
    end

    test "rejects path traversal" do
      assert {:error, msg} =
               ModSmith.validate([%{"path" => "sites/../../etc/x", "content" => ""}])

      assert msg =~ "traversal"
    end

    test "rejects paths outside sites//mods/" do
      assert {:error, _} =
               ModSmith.validate([%{"path" => "lib/evil.ex", "content" => ""}])
    end

    test "rejects oversized files" do
      big = String.duplicate("a", 200_001)
      assert {:error, _} = ModSmith.validate([%{"path" => "sites/a/b.css", "content" => big}])
    end

    test "rejects broken elixir in mods" do
      assert {:error, _} =
               ModSmith.validate([%{"path" => "mods/bad.ex", "content" => "defmodule Oops do"}])
    end

    test "accepts valid elixir mods" do
      assert :ok =
               ModSmith.validate([
                 %{"path" => "mods/ok.ex", "content" => "defmodule Ok do\nend"}
               ])
    end
  end

  describe "parse_followup/1" do
    test "bare refinement targets the latest session" do
      assert ModSmith.parse_followup(" make it smaller") == {:latest, "make it smaller"}
    end

    test "digit glued to do+ selects a session by number" do
      assert ModSmith.parse_followup("2 make it smaller") == {2, "make it smaller"}
    end

    test "a request starting with a number is NOT a selector (space after do+)" do
      assert ModSmith.parse_followup(" 2x faster panning") == {:latest, "2x faster panning"}
    end

    test "selector with no request peeks at that session" do
      assert ModSmith.parse_followup("3") == {3, ""}
    end

    test "empty input is a noop" do
      assert ModSmith.parse_followup("") == {:latest, ""}
    end
  end

  describe "remember_session/2" do
    defp entry(id, at \\ 0), do: %{id: id, request: "r", summary: "s", host: "h", at: at}

    test "a new session is prepended" do
      assert [%{id: "b"}, %{id: "a"}] =
               ModSmith.remember_session([entry("a")], entry("b"))
    end

    test "a refinement replaces its lineage entry and moves it to the front" do
      sessions = [entry("a"), entry("b"), entry("c")]
      updated = %{id: "b2", request: "r2", summary: "s2", host: "h", at: 1, refined: "b"}
      assert [%{id: "b2"}, %{id: "a"}, %{id: "c"}] =
               ModSmith.remember_session(sessions, updated)
    end

    test "history is capped at 8" do
      sessions = for i <- 1..8, do: entry("s#{i}")
      assert length(ModSmith.remember_session(sessions, entry("new"))) == 8
      assert [%{id: "new"} | _] = ModSmith.remember_session(sessions, entry("new"))
    end
  end

  describe "auth_route/1" do
    test "no router settings -> the user's own claude CLI login" do
      assert ModSmith.auth_route(%{}) == :cli
      assert ModSmith.auth_route(%{"dodorouter_endpoint" => "", "dodorouter_api_key" => " "}) ==
               :cli
    end

    test "endpoint + key -> router" do
      settings = %{"dodorouter_endpoint" => "https://r.example", "dodorouter_api_key" => "tok"}
      assert ModSmith.auth_route(settings) == {:router, "https://r.example"}
    end

    test "half-configured router names the missing key" do
      assert ModSmith.auth_route(%{"dodorouter_endpoint" => "https://r.example"}) ==
               {:missing, "dodorouter_api_key"}

      assert ModSmith.auth_route(%{"dodorouter_api_key" => "tok"}) ==
               {:missing, "dodorouter_endpoint"}
    end
  end

  describe "claude_env/1" do
    test "router settings become the CLI's routing env" do
      settings = %{"dodorouter_endpoint" => "https://r.example", "dodorouter_api_key" => "tok"}

      assert ModSmith.claude_env(settings) == [
               {"ANTHROPIC_BASE_URL", "https://r.example"},
               {"CLAUDE_CODE_OAUTH_TOKEN", "tok"}
             ]
    end

    test "cli route inherits the environment untouched" do
      assert ModSmith.claude_env(%{}) == []
    end
  end

  describe "auth_hint/1" do
    test "cli failures teach both auth paths" do
      hint = ModSmith.auth_hint(:cli)
      assert hint =~ "claude"
      assert hint =~ "dodorouter_endpoint"
    end

    test "router failures point at the router config" do
      assert ModSmith.auth_hint({:router, "https://r.example"}) =~ "https://r.example"
    end
  end

  describe "timeout_ms/1" do
    test "defaults to 15 minutes when unset" do
      assert ModSmith.timeout_ms(nil) == 900_000
    end

    test "owner override via :set modsmith_timeout_ms" do
      assert ModSmith.timeout_ms("300000") == 300_000
    end

    test "garbage or non-positive values fall back to the default" do
      assert ModSmith.timeout_ms("soon") == 900_000
      assert ModSmith.timeout_ms("0") == 900_000
      assert ModSmith.timeout_ms("-5") == 900_000
    end
  end

  describe "progress_lines/1 (stream-json narration)" do
    test "assistant prose is trimmed and collapsed" do
      ev = %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "  Reading the\n  dock mod first. "}]}}
      assert ModSmith.progress_lines(ev) == ["Reading the dock mod first."]
    end

    test "tool calls show the tool and its key argument" do
      ev = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{"type" => "tool_use", "name" => "mcp__bowser__read_mod", "input" => %{"path" => "mods/edge_dock_tabs.ex"}},
            %{"type" => "tool_use", "name" => "mcp__bowser__list_mods", "input" => %{}},
            %{"type" => "tool_use", "name" => "mcp__bowser__page_eval", "input" => %{"js" => "document.title"}}
          ]
        }
      }

      assert ModSmith.progress_lines(ev) == [
               "→ read_mod mods/edge_dock_tabs.ex",
               "→ list_mods",
               "→ page_eval document.title"
             ]
    end

    test "empty text, system, user and result events narrate nothing" do
      blank = %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "  \n"}]}}
      assert ModSmith.progress_lines(blank) == []
      assert ModSmith.progress_lines(%{"type" => "system", "subtype" => "init"}) == []
      assert ModSmith.progress_lines(%{"type" => "result", "result" => "{}"}) == []
    end
  end

  describe "stream_result/1" do
    test "takes text and session id from the result event" do
      events = [
        %{"type" => "system"},
        %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "thinking"}]}},
        %{"type" => "result", "result" => ~s({"tier":"mod"}), "session_id" => "sess-1"}
      ]

      assert ModSmith.stream_result(events) == {"sess-1", ~s({"tier":"mod"})}
    end

    test "falls back to assistant prose when no result event arrived" do
      events = [
        %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "part one"}]}},
        %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "part two"}]}}
      ]

      assert ModSmith.stream_result(events) == {nil, "part one\npart two"}
      assert ModSmith.stream_result([]) == {nil, nil}
    end
  end

  describe "panel targets" do
    test "no target is a fresh request" do
      assert ModSmith.request_for(nil, [], "dark mode") == {"dark mode", []}
    end

    test "modify target wraps the change with the file and the MODIFY contract" do
      {req, opts} = ModSmith.request_for(%{kind: :modify, path: "mods/dock.ex"}, [], "bigger icons")
      assert req =~ "Modify the existing file mods/dock.ex"
      assert req =~ "read_mod"
      assert req =~ "Change: bigger icons"
      assert opts == []
    end

    test "refine target resumes that session; a gone session is an error" do
      sessions = [%{id: "s-1", summary: "a", host: "x.com"}, %{id: "s-2", summary: "b", host: "y.com"}]
      assert ModSmith.request_for(%{kind: :refine, n: 2}, sessions, "tighter") == {"tighter", [resume: "s-2"]}
      assert {:error, msg} = ModSmith.request_for(%{kind: :refine, n: 5}, sessions, "x")
      assert msg =~ "#5"
    end

    test "placeholders name the target" do
      assert ModSmith.placeholder_for(nil) =~ "What should this page do"
      assert ModSmith.placeholder_for(%{kind: :modify, path: "sites/x.com/tweet-font.css"}) =~ "tweet-font.css"
      assert ModSmith.placeholder_for(%{kind: :refine, n: 3}) =~ "#3"
    end
  end

  describe "panel tree" do
    defp base, do: %{sessions: [], last_status: "Ready.", progress: [], busy: nil}

    test "status_line maps every outcome to glyph/label/detail" do
      assert ModSmith.status_line("Working on: dark mode", "Ready.") == {"●", "Working", "dark mode"}
      assert ModSmith.status_line(nil, "Done: added a tag") == {"✓", "Done", "added a tag"}
      assert ModSmith.status_line(nil, "Failed: claude exited 1") == {"✗", "Failed", "claude exited 1"}
      assert ModSmith.status_line(nil, "↗ NEEDS THE RESIDENT AGENT: big") == {"↗", "Handed off", "NEEDS THE RESIDENT AGENT: big"}
      assert ModSmith.status_line(nil, "Ready.") == {"○", "Ready", nil}
    end

    test "request field first, no inner title, no footer, no mode row when untargeted" do
      %{children: [first | rest]} = ModSmith.tree(base())
      assert first.t == "textfield"
      refute Enum.any?(rest, &(&1.t == "text" and &1.value in ["ModSmith", "Forge 9811"]))
      refute Enum.any?(rest, &(&1.t == "text" and String.contains?(&1.value, "Enter sends")))
      refute Enum.any?(rest, &(&1.t == "hstack"))
      assert Enum.any?(rest, &(&1.t == "text" and &1.value == "○ Ready"))
    end

    test "log lines are mono, oldest first, capped at 6" do
      progress = for i <- 1..9, do: "line #{i}"
      %{children: kids} = ModSmith.tree(Map.put(base(), :progress, progress))
      mono = for %{t: "text", style: :mono, value: v} <- kids, do: v
      assert mono == ["line 6", "line 5", "line 4", "line 3", "line 2", "line 1"]
    end

    test "sessions are compact buttons; the picked one is active; target shows a mode row" do
      state =
        base()
        |> Map.put(:sessions, [%{id: "a", summary: "one", host: "x.com"}, %{id: "b", summary: "two", host: "y.com"}])
        |> Map.put(:target, %{kind: :refine, n: 2})

      %{children: kids} = ModSmith.tree(state)
      rows = for %{t: "button", event: "pick"} = b <- kids, do: b
      assert Enum.map(rows, & &1.compact) == [true, true]
      assert Enum.map(rows, & &1.active) == [false, true]
      assert Enum.any?(kids, &(&1.t == "hstack"))
    end
  end

  describe "run salvage" do
    defp acc, do: %{events: [], raw: [], partial: "", session: nil, started: System.monotonic_time(:millisecond)}

    test "session_of reads the id from init and result events only" do
      assert ModSmith.session_of(%{"type" => "system", "subtype" => "init", "session_id" => "s1"}) == "s1"
      assert ModSmith.session_of(%{"type" => "result", "session_id" => "s2"}) == "s2"
      assert ModSmith.session_of(%{"type" => "assistant", "session_id" => "s3"}) == nil
    end

    test "stream_loop keeps the session id and reports it on timeout" do
      fake = make_ref()
      send(self(), {fake, {:data, {:eol, JSON.encode!(%{"type" => "system", "subtype" => "init", "session_id" => "sess-9"})}}})
      deadline = System.monotonic_time(:millisecond) + 60
      assert {:timeout, "sess-9"} = ModSmith.stream_loop(fake, deadline, fn _ -> :ok end, acc())
    end

    test "stream_loop returns events, raw lines and session on exit" do
      fake = make_ref()
      me = self()
      send(self(), {fake, {:data, {:eol, JSON.encode!(%{"type" => "system", "subtype" => "init", "session_id" => "sess-1"})}}})
      send(self(), {fake, {:data, {:eol, "not json"}}})
      send(self(), {fake, {:data, {:eol, JSON.encode!(%{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => "hi"}]}})}}})
      send(self(), {fake, {:exit_status, 0}})
      deadline = System.monotonic_time(:millisecond) + 5_000
      assert {:done, 0, events, ["not json"], "sess-1"} = ModSmith.stream_loop(fake, deadline, &send(me, {:p, &1}), acc())
      assert length(events) == 2
      assert_received {:p, "hi"}
    end

    test "finish_prompt demands the envelope and allows an honest handoff" do
      assert ModSmith.finish_prompt() =~ "ONLY the JSON envelope"
      assert ModSmith.finish_prompt() =~ "NEEDS THE RESIDENT AGENT"
    end
  end
end
