defmodule BowserBrain.CookieScopeTest do
  use ExUnit.Case, async: true
  alias BowserBrain.Bridge

  test "cookie targets require explicit web hosts" do
    for value <- [nil, "", "file:///tmp/a", "https:///", "https://user:pass@example.com", "data:text/plain,a"] do
      refute Bridge.valid_cookie_url?(value)
      assert {:error, :invalid_cookie_scope} = Bridge.get_cookies_for(value, "default")
    end
    assert Bridge.valid_cookie_url?("https://www.youtube.com")
  end

  test "scoped mods cannot request a different profile" do
    Process.put(:bowser_profile, "work")
    assert {:error, :invalid_cookie_scope} = Bridge.get_cookies_for("https://example.com", "default")
    assert {:error, :invalid_cookie_scope} = Bridge.get_cookies_for("https://example.com", nil)
  end
end
