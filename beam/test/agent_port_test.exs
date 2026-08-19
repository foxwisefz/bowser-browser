defmodule BowserBrain.AgentPortTest do
  use ExUnit.Case, async: false

  alias BowserBrain.AgentPort

  test "list_tabs returns the session mirror shape" do
    assert %{ok: true, tabs: tabs, active: _} = AgentPort.dispatch(%{"tool" => "list_tabs"})
    assert is_list(tabs)
  end

  test "page_eval without a live engine reports the error instead of raising" do
    # Hermetic env: bridge is disconnected — the tool must degrade to a
    # readable error the model can act on.
    assert %{ok: false, error: error} =
             AgentPort.dispatch(%{"tool" => "page_eval", "args" => %{"js" => "1+1"}})

    assert is_binary(error)
  end

  test "put_payload validates like ModSmith and refuses traversal" do
    assert %{ok: false, error: error} =
             AgentPort.dispatch(%{
               "tool" => "put_payload",
               "args" => %{"host" => "../etc", "name" => "x.css", "content" => "body{}"}
             })

    assert error =~ "host"
  end

  test "put_payload refuses non-css/js names" do
    assert %{ok: false, error: _} =
             AgentPort.dispatch(%{
               "tool" => "put_payload",
               "args" => %{"host" => "x.com", "name" => "evil.ex", "content" => "x"}
             })
  end

  test "unknown tools error cleanly" do
    assert %{ok: false, error: error} = AgentPort.dispatch(%{"tool" => "rm_rf"})
    assert error =~ "unknown tool"
  end
end
