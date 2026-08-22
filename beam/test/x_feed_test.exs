defmodule BowserBrain.XFeedTest do
  use ExUnit.Case, async: true

  alias BowserBrain.XFeed

  describe "route_url/1" do
    test "home" do
      assert XFeed.route_url("home") == "https://x.com/home"
    end

    test "profile and sub-routes" do
      assert XFeed.route_url("@tealtoronto") == "https://x.com/tealtoronto"
      assert XFeed.route_url("@tealtoronto/likes") == "https://x.com/tealtoronto/likes"
    end

    test "search encodes the query and asks for the live tab" do
      assert XFeed.route_url("search:elixir lang") ==
               "https://x.com/search?q=elixir%20lang&f=live"
    end

    test "bare path passes through" do
      assert XFeed.route_url("explore") == "https://x.com/explore"
      assert XFeed.route_url("/i/bookmarks") == "https://x.com/i/bookmarks"
    end
  end
end

defmodule BowserBrain.XFeedMergeTest do
  use ExUnit.Case, async: true

  # merge/2 is private; exercise it through a tiny reimplementation contract
  # by asserting the observable behavior via XServer.split_want (public) and
  # documenting the dedup expectation in x_feed_test proper is enough — but
  # we can still test the want parser here.
  alias BowserBrain.XServer

  test "split_want parses and clamps the want param" do
    assert XServer.split_want("/x/home") == {"/x/home", 15}
    assert XServer.split_want("/x/home?want=40") == {"/x/home", 40}
    assert XServer.split_want("/x/home?want=0") == {"/x/home", 15}
    assert XServer.split_want("/x/home?want=9999") == {"/x/home", 15}
    assert XServer.split_want("/x/@ada?want=30") == {"/x/@ada", 30}
  end
end
