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
