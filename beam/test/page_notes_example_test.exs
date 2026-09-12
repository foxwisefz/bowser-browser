defmodule BowserBrain.PageNotesExampleTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{Store, Toolbars}

  setup_all do
    Code.compile_file(Path.expand("../example_mods/page_notes.ex", __DIR__))
    :ok
  end

  setup do
    previous = Application.get_env(:bowser_brain, :data_dir)
    dir = Path.join(System.tmp_dir!(), "native-note-#{System.unique_integer([:positive])}")
    Application.put_env(:bowser_brain, :data_dir, dir)
    on_exit(fn ->
      Application.put_env(:bowser_brain, :data_dir, previous)
      File.rm_rf!(dir)
    end)
    Store.clear(PageNotes)
    :ok
  end

  test "native saves retain newlines and target the original URL after switching tabs" do
    state = %{active: 2, url: "https://second.test", contexts: %{"first" => %{url: "https://first.test", body: ""}}, response: nil}
    draft = "# Private 🐝\n\n**multiline**\n- item"
    event = %{"event" => "surface", "surface" => "toolbar:page_notes_sidebar", "id" => "notes_save:first",
      "value" => %{"request_id" => "save-1", "values" => %{"body" => draft}}}
    result = PageNotes.handle_event(event, state)
    assert result.response == %{request_id: "save-1", ok: true, values: %{"body" => draft}}
    assert Store.get(PageNotes, "notes")["https://first.test"]["body"] == draft
    refute Map.has_key?(Store.get(PageNotes, "notes"), "https://second.test")
    Store.put(PageNotes, "notes", %{"https://first.test" => %{"body" => "edited elsewhere"}})
    result = PageNotes.handle_event(event, result)
    assert result.response.ok == false
    assert Store.get(PageNotes, "notes")["https://first.test"]["body"] == "edited elsewhere"
    Toolbars.release(self())
  end

  test "page messages cannot invoke native note saving" do
    state = %{active: 1, url: "https://first.test", contexts: %{}, response: nil}
    assert PageNotes.handle_event(%{"event" => "page", "payload" => %{"action" => "save", "body" => "injected"}}, state) == state
    assert Store.get(PageNotes, "notes", %{}) == %{}
  end
end
