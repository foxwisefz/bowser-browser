defmodule BowserBrain.ModAuditorTest do
  use ExUnit.Case, async: true
  alias BowserBrain.ModAuditor

  test "audit CLI has no tools, MCP servers, session reuse or project hooks" do
    args = BowserBrain.ModSmith.audit_args("untrusted source")
    value = fn flag -> Enum.at(args, Enum.find_index(args, &(&1 == flag)) + 1) end
    assert value.("--tools") == ""
    assert value.("--allowedTools") == ""
    assert JSON.decode!(value.("--mcp-config")) == %{"mcpServers" => %{}}
    assert "--strict-mcp-config" in args
    assert "--no-session-persistence" in args
    assert "--disable-slash-commands" in args
    refute "--resume" in args
    assert value.("--setting-sources") == ""
    assert JSON.decode!(value.("--settings"))["disableAllHooks"] == true
  end

  test "only strict explicit allow for this exact digest and nonce is accepted" do
    hash = ModAuditor.digest("exact source")
    valid = %{"verdict" => "allow", "sha256" => hash, "nonce" => "request-1", "reason" => "Reviewed"}
    assert :ok = ModAuditor.verdict(JSON.encode!(valid), hash, "request-1")
    for invalid <- [Map.put(valid, "verdict", "reject"), Map.put(valid, "verdict", "uncertain"),
      Map.put(valid, "verdict", true), Map.put(valid, "sha256", "other"), Map.put(valid, "nonce", "other"),
      Map.put(valid, "approved", true), Map.delete(valid, "reason"), Map.put(valid, "reason", "")] do
      assert {:error, _} = ModAuditor.verdict(JSON.encode!(invalid), hash, "request-1")
    end
    duplicate = "{\"verdict\":\"reject\"," <> String.trim_leading(JSON.encode!(valid), "{")
    assert {:error, _} = ModAuditor.verdict(duplicate, hash, "request-1")
    for output <- ["approved", "```json\n#{JSON.encode!(valid)}\n```", "[]", "null", JSON.encode!(valid) <> " extra"] do
      assert {:error, _} = ModAuditor.verdict(output, hash, "request-1")
    end
  end
end
