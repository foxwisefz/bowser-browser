defmodule BowserBrain.ProfilesTest do
  use ExUnit.Case, async: false

  alias BowserBrain.Profiles

  setup do
    path = Path.join(System.tmp_dir!(), "profiles-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:bowser_brain, :profiles_path)
    Application.put_env(:bowser_brain, :profiles_path, path)
    on_exit(fn ->
      if previous, do: Application.put_env(:bowser_brain, :profiles_path, previous), else: Application.delete_env(:bowser_brain, :profiles_path)
      File.rm(path)
    end)
    :ok
  end

  test "the default profile always exists and comes first" do
    assert [%{"id" => "default", "name" => "Personal"}] = Profiles.list()
    {:ok, _} = Profiles.create("Work", tint: "blue", icon: "🧪")
    assert ["default", "work"] = Enum.map(Profiles.list(), & &1["id"])
  end

  test "create slugs the id, normalizes the tint, mints a uuid; duplicates refused" do
    {:ok, p} = Profiles.create("Side Hustle!", tint: "#ABC", icon: "💼")
    assert %{"id" => "side-hustle", "name" => "Side Hustle!", "tint" => "#aabbcc", "icon" => "💼"} = p
    assert String.match?(p["uuid"], ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
    assert {:error, _} = Profiles.create("side hustle!")
    assert {:error, _} = Profiles.create("   ")
    assert Profiles.by_name("SIDE HUSTLE!")["id"] == "side-hustle"
    assert Profiles.by_name("side-hustle")["id"] == "side-hustle"
  end

  test "normalize_tint: hex, short hex, names, garbage" do
    assert Profiles.normalize_tint("#3E63DD") == "#3e63dd"
    assert Profiles.normalize_tint("#fff") == "#ffffff"
    assert Profiles.normalize_tint("Blue") == "#3e63dd"
    assert Profiles.normalize_tint("chartreuse-ish") == nil
    assert Profiles.normalize_tint(nil) == nil
  end

  test "parse_new pulls tint and emoji out of the words" do
    assert Profiles.parse_new("work blue 🧪") == {"work", "#3e63dd", "🧪"}
    assert Profiles.parse_new("🎮 gaming #ff0000") == {"gaming", "#ff0000", "🎮"}
    assert Profiles.parse_new("just a name") == {"just a name", nil, nil}
  end

  test "update and delete; the default cannot be deleted" do
    {:ok, _} = Profiles.create("Work")
    {:ok, p} = Profiles.update("work", %{"tint" => "green", "icon" => "🏢"})
    assert p["tint"] == "#30a46c" and p["icon"] == "🏢"
    assert {:error, _} = Profiles.delete("default")
    :ok = Profiles.delete("work")
    assert Enum.map(Profiles.list(), & &1["id"]) == ["default"]
  end

  test "edit_event parses field|id" do
    assert Profiles.edit_event("tint|work") == {"tint", "work"}
    assert Profiles.edit_event("name|default") == {"name", "default"}
    assert Profiles.edit_event("open") == nil
    assert Profiles.edit_event("bogus|x") == nil
  end

  test "edit validates: unknown color refused, duplicate/empty name refused, empty clears" do
    {:ok, _} = Profiles.create("Work", tint: "blue", icon: "🧪")
    {:ok, _} = Profiles.create("Play")
    assert {:error, msg} = Profiles.edit("work", "tint", "chartreuse-ish")
    assert msg =~ "unknown color"
    assert Profiles.get("work")["tint"] == "#3e63dd"
    assert {:ok, %{"tint" => "#30a46c"}} = Profiles.edit("work", "tint", "green")
    assert {:ok, %{"tint" => nil}} = Profiles.edit("work", "tint", "")
    assert {:ok, %{"icon" => nil}} = Profiles.edit("work", "icon", " ")
    assert {:error, _} = Profiles.edit("work", "name", "")
    assert {:error, _} = Profiles.edit("work", "name", "play")
    assert {:ok, %{"name" => "Work"}} = Profiles.edit("work", "name", "Work")
    assert {:ok, %{"name" => "Werk"}} = Profiles.edit("work", "name", "Werk")
    assert {:error, _} = Profiles.edit("nope", "name", "x")
  end
end
