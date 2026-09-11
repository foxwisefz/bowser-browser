defmodule BowserBrain.SettingsTest do
  use ExUnit.Case, async: false
  alias BowserBrain.Settings

  setup do
    root = Path.join(System.tmp_dir!(), "settings-#{System.unique_integer([:positive])}")
    old_path = Application.get_env(:bowser_brain, :settings_path)
    old_state = :sys.get_state(Settings)
    Application.put_env(:bowser_brain, :settings_path, Path.join(root, "settings.json"))

    assert Settings.path() == Path.join(root, "settings.json"),
           "Refusing settings writes outside the fixture"

    :sys.replace_state(Settings, fn _ -> %{declared: %{}} end)

    on_exit(fn ->
      :sys.replace_state(Settings, fn _ -> old_state end)

      if old_path,
        do: Application.put_env(:bowser_brain, :settings_path, old_path),
        else: Application.delete_env(:bowser_brain, :settings_path)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "settings roundtrip through isolated disk, preserving unrelated keys", %{root: root} do
    assert Settings.path() == Path.join(root, "settings.json")
    assert Settings.get("missing", "fallback") == "fallback"
    assert :ok = Settings.put("first", "hello")
    assert :ok = Settings.put("second", "world")
    assert JSON.decode!(File.read!(Settings.path())) == %{"first" => "hello", "second" => "world"}
    assert :ok = Settings.delete("first")
    assert Settings.all() == %{"second" => "world"}
    File.write!(Settings.path(), "invalid json")
    assert Settings.all() == %{}
  end

  test "deleting an unset key works before the settings directory exists" do
    assert :ok = Settings.delete("absent")
    assert Settings.all() == %{}
  end

  test "declared and inferred secrets never expose even short values in summaries" do
    Settings.declare("credential", secret: true, about: "Service login")
    Settings.declare("not_configured", about: "Optional setting")
    Settings.put("credential", "abc")
    Settings.put("api_token", "uniquesecret123")
    Settings.put("theme", "dark")
    summary = Settings.summary()
    assert Settings.declarations()["credential"].secret
    assert summary =~ "Service login"
    assert summary =~ "NOT set"
    assert summary =~ "dark"
    refute summary =~ "abc"
    refute summary =~ "unique"
  end
end
