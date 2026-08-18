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
