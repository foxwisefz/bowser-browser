defmodule BowserBrain.SessionTest do
  # Session state transitions are tested by driving handle_info/2 directly —
  # no engine, no socket. Outbound casts go to the (disconnected) Bridge and
  # are dropped; what we assert is the state machine.
  use ExUnit.Case, async: false

  alias BowserBrain.Session

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "session.json")
    old = Application.get_env(:bowser_brain, :session_path)
    Application.put_env(:bowser_brain, :session_path, path)
    on_exit(fn ->
      if old,
        do: Application.put_env(:bowser_brain, :session_path, old),
        else: Application.delete_env(:bowser_brain, :session_path)
    end)

    {:ok, path: path}
  end

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{tabs: %{}, active: nil, cookies: %{}, disk: %{urls: [], active: 0}, restore: nil},
      overrides
    )
  end

  defp event(state, map) do
    {:noreply, state} = Session.handle_info({:browser_event, map}, state)
    state
  end

  test "tab_activated tracks the active webview" do
    state =
      base_state()
      |> event(%{"event" => "url_changed", "webview" => 1, "url" => "https://a.example/"})
      |> event(%{"event" => "url_changed", "webview" => 2, "url" => "https://b.example/"})
      |> event(%{"event" => "tab_activated", "webview" => 2})

    assert state.active == 2
  end

  test "closing the active webview clears active" do
    state =
      base_state(%{tabs: %{1 => "https://a.example/"}, active: 1})
      |> event(%{"event" => "webview_closed", "webview" => 1})

    assert state.active == nil
    assert state.tabs == %{}
  end

  test "persist writes urls and the active index to disk", %{path: path} do
    base_state()
    |> event(%{"event" => "url_changed", "webview" => 1, "url" => "https://a.example/"})
    |> event(%{"event" => "url_changed", "webview" => 2, "url" => "https://b.example/"})
    |> event(%{"event" => "url_changed", "webview" => 3, "url" => "https://c.example/"})
    |> event(%{"event" => "tab_activated", "webview" => 2})

    assert {:ok, raw} = File.read(path)
    assert {:ok, %{"urls" => urls, "active" => 1}} = JSON.decode(raw)
    assert urls == ["https://a.example/", "https://b.example/", "https://c.example/"]
  end

  test "load_disk accepts the new map format and the legacy bare list", %{path: path} do
    File.write!(path, JSON.encode!(%{urls: ["https://a.example/"], active: 0}))
    assert Session.load_disk() == %{urls: ["https://a.example/"], active: 0}

    File.write!(path, JSON.encode!(["https://a.example/", "https://b.example/"]))
    assert Session.load_disk() == %{urls: ["https://a.example/", "https://b.example/"], active: 0}

    # Out-of-range active clamps to 0 rather than pointing past the list.
    File.write!(path, JSON.encode!(%{urls: ["https://a.example/"], active: 7}))
    assert Session.load_disk() == %{urls: ["https://a.example/"], active: 0}
  end

  test "hello adoption takes the engine's active tab" do
    state =
      base_state()
      |> event(%{
        "event" => "hello",
        "tabs" => [
          %{"id" => 1, "url" => "https://a.example/"},
          %{"id" => 2, "url" => "https://b.example/"}
        ],
        "active" => 2
      })

    assert state.tabs == %{1 => "https://a.example/", 2 => "https://b.example/"}
    assert state.active == 2
  end

  test "fresh-engine restore arms activation for the remembered active tab" do
    state =
      base_state(%{
        tabs: %{
          1 => "https://a.example/",
          2 => "https://b.example/",
          3 => "https://c.example/"
        },
        active: 3
      })
      |> event(%{"event" => "hello", "tabs" => [%{"id" => 1, "url" => nil}], "active" => 1})

    # Active was the 3rd remembered tab: the 2nd open_tab after restore is it.
    assert state.restore == %{remaining: 2}

    state = event(state, %{"event" => "tab_opened", "webview" => 2})
    assert state.restore == %{remaining: 1}

    # The counter clears when the active tab's webview appears (and
    # Surface.activate_tab is cast for it — dropped here, no engine).
    state = event(state, %{"event" => "tab_opened", "webview" => 3})
    assert state.restore == nil
  end

  test "restore of an already-visible active tab arms nothing" do
    state =
      base_state(%{
        tabs: %{1 => "https://a.example/", 2 => "https://b.example/"},
        active: 1
      })
      |> event(%{"event" => "hello", "tabs" => [%{"id" => 1, "url" => nil}], "active" => 1})

    assert state.restore == nil
  end

  test "full-stack restore arms activation from the disk active index" do
    state =
      base_state(%{
        disk: %{
          urls: ["https://a.example/", "https://b.example/", "https://c.example/"],
          active: 1
        }
      })
      |> event(%{"event" => "hello", "tabs" => [%{"id" => 1, "url" => nil}], "active" => 1})

    assert state.restore == %{remaining: 1}
  end

  test "tab_opened outside a restore leaves state alone" do
    state = base_state() |> event(%{"event" => "tab_opened", "webview" => 5})
    assert state.restore == nil
  end
end
