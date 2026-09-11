defmodule BowserBrain.XAdapterTest do
  use ExUnit.Case, async: true

  alias BowserBrain.XAdapter

  defp tweet(over \\ %{}) do
    Map.merge(
      %{
        "id" => "123",
        "name" => "  Ada Lovelace ",
        "handle" => "@ada",
        "text" => "  hello world ",
        "permalink" => "https://x.com/ada/status/123",
        "timestamp" => "2026-08-22T00:00:00.000Z",
        "photos" => ["https://pbs.twimg.com/a.jpg"],
        "has_video" => false,
        "metrics" => %{"replies" => "2", "reposts" => "5", "likes" => "40", "views" => "1.2K"}
      },
      over
    )
  end

  test "normalizes fields and trims whitespace" do
    [t] = XAdapter.normalize([tweet()])
    assert t.id == "123"
    assert t.name == "Ada Lovelace"
    assert t.handle == "@ada"
    assert t.text == "hello world"
    assert t.photos == ["https://pbs.twimg.com/a.jpg"]
    assert t.metrics == %{replies: "2", reposts: "5", likes: "40", views: "1.2K"}
  end

  test "drops empty rows (ads, dividers) but keeps text-only tweets" do
    rows = [tweet(), %{"id" => nil, "text" => nil}, tweet(%{"id" => nil, "text" => "just text"})]
    result = XAdapter.normalize(rows)
    assert length(result) == 2
    assert Enum.map(result, & &1.text) == ["hello world", "just text"]
  end

  test "dedupes by id" do
    result = XAdapter.normalize([tweet(), tweet(%{"text" => "same id, later render"})])
    assert length(result) == 1
  end

  test "missing metrics default to '0', not crash" do
    [t] = XAdapter.normalize([tweet(%{"metrics" => nil})])
    assert t.metrics == %{replies: "0", reposts: "0", likes: "0", views: "0"}
  end

  test "nil-safe on sparse rows" do
    [t] = XAdapter.normalize([%{"id" => "9", "text" => nil, "name" => nil, "handle" => nil}])
    assert t.id == "9"
    assert t.name == nil
    assert t.photos == []
  end
end
