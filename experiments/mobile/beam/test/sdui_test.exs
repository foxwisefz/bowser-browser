defmodule BowserBrain.SDUITest do
  use ExUnit.Case, async: true

  alias BowserBrain.{SDUI, XServer}

  test "x_timeline is a screen wrapping a data-bound list" do
    screen = SDUI.x_timeline("Home")
    assert screen["type"] == "screen"
    assert screen["title"] == "Home"
    assert screen["list"]["data"] == "tweets"
    assert screen["list"]["item"]["type"] == "vstack"
  end

  test "tweet_card binds the normalized tweet fields" do
    binds =
      SDUI.tweet_card()
      |> collect_binds()
      |> Enum.sort()

    assert "name" in binds
    assert "handle" in binds
    assert "text" in binds
    assert "photos.0" in binds
    assert "metrics.likes" in binds
  end

  test "builders omit absent optional keys" do
    assert SDUI.text(bind: "x") == %{"type" => "text", "bind" => "x"}
    assert SDUI.spacer() == %{"type" => "spacer"}
    refute Map.has_key?(SDUI.vstack([]), "bind")
  end

  test "the whole declaration is JSON-encodable" do
    assert is_binary(JSON.encode!(SDUI.x_timeline()))
  end

  test "server route matching" do
    assert XServer.route("/health") == {200, "ok"}
    assert {404, _} = XServer.route("/nope")
  end

  defp collect_binds(node) when is_map(node) do
    here = if node["bind"], do: [node["bind"]], else: []
    kids = node |> Map.get("children", []) |> Enum.flat_map(&collect_binds/1)
    item = if node["item"], do: collect_binds(node["item"]), else: []
    here ++ kids ++ item
  end

  defp collect_binds(_), do: []
end
