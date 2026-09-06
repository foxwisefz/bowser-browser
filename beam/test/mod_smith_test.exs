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
      ev = %{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "text", "text" => "  Reading the\n  dock mod first. "}]
        }
      }

      assert ModSmith.progress_lines(ev) == ["Reading the dock mod first."]
    end

    test "tool calls show the tool and its key argument" do
      ev = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "name" => "mcp__bowser__read_mod",
              "input" => %{"path" => "mods/edge_dock_tabs.ex"}
            },
            %{"type" => "tool_use", "name" => "mcp__bowser__list_mods", "input" => %{}},
            %{
              "type" => "tool_use",
              "name" => "mcp__bowser__page_eval",
              "input" => %{"js" => "document.title"}
            }
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
      blank = %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "text", "text" => "  \n"}]}
      }

      assert ModSmith.progress_lines(blank) == []
      assert ModSmith.progress_lines(%{"type" => "system", "subtype" => "init"}) == []
      assert ModSmith.progress_lines(%{"type" => "result", "result" => "{}"}) == []
    end
  end

  describe "stream_result/1" do
    test "takes text and session id from the result event" do
      events = [
        %{"type" => "system"},
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "thinking"}]}
        },
        %{"type" => "result", "result" => ~s({"tier":"mod"}), "session_id" => "sess-1"}
      ]

      assert ModSmith.stream_result(events) == {"sess-1", ~s({"tier":"mod"})}
    end

    test "falls back to assistant prose when no result event arrived" do
      events = [
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "part one"}]}
        },
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "part two"}]}
        }
      ]

      assert ModSmith.stream_result(events) == {nil, "part one\npart two"}
      assert ModSmith.stream_result([]) == {nil, nil}
    end
  end

  describe "run salvage" do
    defp acc,
      do: %{
        events: [],
        raw: [],
        partial: "",
        session: nil,
        started: System.monotonic_time(:millisecond)
      }

    test "session_of reads the id from init and result events only" do
      assert ModSmith.session_of(%{"type" => "system", "subtype" => "init", "session_id" => "s1"}) ==
               "s1"

      assert ModSmith.session_of(%{"type" => "result", "session_id" => "s2"}) == "s2"
      assert ModSmith.session_of(%{"type" => "assistant", "session_id" => "s3"}) == nil
    end

    test "stream_loop keeps the session id and reports it on timeout" do
      fake = make_ref()

      send(
        self(),
        {fake,
         {:data,
          {:eol,
           JSON.encode!(%{"type" => "system", "subtype" => "init", "session_id" => "sess-9"})}}}
      )

      deadline = System.monotonic_time(:millisecond) + 60
      assert {:timeout, "sess-9"} = ModSmith.stream_loop(fake, deadline, fn _ -> :ok end, acc())
    end

    test "stream_loop returns events, raw lines and session on exit" do
      fake = make_ref()
      me = self()

      send(
        self(),
        {fake,
         {:data,
          {:eol,
           JSON.encode!(%{"type" => "system", "subtype" => "init", "session_id" => "sess-1"})}}}
      )

      send(self(), {fake, {:data, {:eol, "not json"}}})

      send(
        self(),
        {fake,
         {:data,
          {:eol,
           JSON.encode!(%{
             "type" => "assistant",
             "message" => %{"content" => [%{"type" => "text", "text" => "hi"}]}
           })}}}
      )

      send(self(), {fake, {:exit_status, 0}})
      deadline = System.monotonic_time(:millisecond) + 5_000

      assert {:done, 0, events, ["not json"], "sess-1"} =
               ModSmith.stream_loop(fake, deadline, &send(me, {:p, &1}), acc())

      assert length(events) == 2
      assert_received {:p, "hi"}
    end

    test "finish_prompt demands the envelope and allows an honest handoff" do
      assert ModSmith.finish_prompt() =~ "ONLY the JSON envelope"
      assert ModSmith.finish_prompt() =~ "NEEDS THE RESIDENT AGENT"
    end
  end
end
