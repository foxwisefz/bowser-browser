defmodule BowserBrain.ResourceControllerTest do
  use ExUnit.Case, async: true
  alias BowserBrain.ResourceController, as: Controller
  defp window, do: %{"id" => "w", "profile" => "work", "tabs" => [1, 2, 3], "active" => 2, "panes" => []}
  test "resource capability is explicit and retained in handoff identity" do
    alias BowserBrain.Bridge
    assert Bridge.resource_identity(%{})["resource_protocol"] == nil
    identity = Bridge.resource_identity(%{"engine_build_id" => "host", "resources" => %{"version" => 1, "windows" => [%{"profile" => "work"}]}})
    assert identity["resource_protocol"] == 1
    refute Map.has_key?(identity, "resources")
    assert Bridge.resource_identity(identity) == identity
    assert Bridge.resource_identity(%{"resources" => %{"version" => 2}})["resource_protocol"] == 2
  end
  test "download policy survives missing source tabs and sanitizes filenames" do
    event = %{"request" => "d", "intent" => %{"action" => "download_destination", "download" => "download-id"},
      "snapshot" => %{"windows" => [], "session" => "native", "next" => 2, "revision" => "rev", "downloads" => [
        %{"id" => "download-id", "profile" => "work", "suggested" => "../../file.bin", "awaiting_destination" => true}]}}
    assert %{command: %{filename: "file.bin", profile: "work", download: "download-id"}} = Controller.decision(event)
    assert Controller.download_filename("..") == "download"
    assert Controller.download_filename("a\u0000b") == "ab"
    assert length(Controller.navigation_rules()) == 2
  end
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
