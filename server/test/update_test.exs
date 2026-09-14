defmodule BowserServer.UpdateTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  @endpoint BowserServerWeb.Endpoint

  test "release assets are not served by the API" do
    for path <- ~w(/Bowser.dmg /updates/stable.json /updates/Bowser.dmg /releases/200/Bowser.dmg) do
      assert get(build_conn(), path).status == 404
    end
  end
end
