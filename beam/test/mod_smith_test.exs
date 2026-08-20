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
    test "defaults to 10 minutes when unset" do
      assert ModSmith.timeout_ms(nil) == 600_000
    end

    test "owner override via :set modsmith_timeout_ms" do
      assert ModSmith.timeout_ms("300000") == 300_000
    end

    test "garbage or non-positive values fall back to the default" do
      assert ModSmith.timeout_ms("soon") == 600_000
      assert ModSmith.timeout_ms("0") == 600_000
      assert ModSmith.timeout_ms("-5") == 600_000
    end
  end
end
