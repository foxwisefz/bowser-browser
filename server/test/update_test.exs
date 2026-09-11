defmodule BowserServer.UpdateTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  @endpoint BowserServerWeb.Endpoint
  test "update files are unavailable until configured and only explicit paths are public" do
    dir = Path.join(System.tmp_dir!(), "bowser-update-#{BowserServer.Store.uuid()}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Application.delete_env(:bowser_server, :update_manifest)
      Application.delete_env(:bowser_server, :update_image)
      File.rm_rf!(dir)
    end)

    assert get(build_conn(), "/updates/stable.json").status == 503
    assert get(build_conn(), "/updates/Bowser.dmg").status == 503
    File.write!(Path.join(dir, "stable.json"), ~s({"payload":"fixture","signature":"fixture"}))
    File.write!(Path.join(dir, "Bowser.dmg"), "image fixture")
    File.write!(Path.join(dir, "private.key"), "not public")
    Application.put_env(:bowser_server, :update_manifest, Path.join(dir, "stable.json"))
    Application.put_env(:bowser_server, :update_image, Path.join(dir, "Bowser.dmg"))
    assert get(build_conn(), "/updates/stable.json").status == 200
    assert get(build_conn(), "/updates/Bowser.dmg").resp_body == "image fixture"
    assert get(build_conn(), "/updates/private.key").status == 404
  end
end
