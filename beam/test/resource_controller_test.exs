defmodule BowserBrain.ResourceControllerTest do
  use ExUnit.Case, async: true
  alias BowserBrain.ResourceController, as: Controller
  defp window, do: %{"id" => "w", "profile" => "work", "tabs" => [1, 2, 3], "active" => 2, "panes" => []}
  test "opening follows current tab and restore append remains explicit" do
    intent = %{"action" => "opened", "tab" => 3, "anchor" => 1, "activate" => false}
    assert %{order: [1, 3, 2], active: 2} = Controller.tab_command(intent, window())
    assert %{order: [1, 2, 3], active: 3} = Controller.tab_command(Map.merge(intent, %{"append" => true, "activate" => true}), window())
  end
  test "closing selects next neighbor, preserves background focus and respects visible panes" do
    assert %{active: 3} = Controller.tab_command(%{"action" => "close", "tab" => 2}, window())
    assert %{active: 2} = Controller.tab_command(%{"action" => "close", "tab" => 3}, window())
    assert %{active: 1} = Controller.tab_command(%{"action" => "close", "tab" => 2}, Map.put(window(), "panes", [1, 2]))
  end
  test "cycles wrap, moves reject foreign tabs, and stale intents are discarded" do
    assert %{active: 1} = Controller.tab_command(%{"action" => "cycle", "tab" => 2, "offset" => 2}, window())
    assert nil == Controller.tab_command(%{"action" => "move", "tab" => 2, "target" => 99}, window())
    event = %{"request" => "r", "intent" => %{"action" => "close", "tab" => 99},
      "snapshot" => %{"windows" => [window()], "session" => "native", "next" => 4, "revision" => "rev"}}
    assert %{discard: true, request: "r", sequence: 4} = Controller.decision(event)
    assert %{command: %{profile: "work", window: "w", revision: "rev", active: 3}} = Controller.decision(put_in(event, ["intent", "tab"], 2))
  end
end
