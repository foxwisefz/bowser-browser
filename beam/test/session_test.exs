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

  test "load_disk accepts tabs-with-profile, the urls map and the legacy bare list", %{path: path} do
    File.write!(path, JSON.encode!(%{tabs: [%{url: "https://w.example/", profile: "work"}, %{url: "https://a.example/"}], active: 1}))
    assert %{tabs: [%{url: "https://w.example/", profile: "work"}, %{url: "https://a.example/", profile: "default"}],
             urls: ["https://w.example/", "https://a.example/"], active: 1} = Session.load_disk()

    File.write!(path, JSON.encode!(%{urls: ["https://a.example/"], active: 0}))
    assert %{tabs: [%{url: "https://a.example/", profile: "default"}], urls: ["https://a.example/"], active: 0} = Session.load_disk()

    File.write!(path, JSON.encode!(["https://a.example/", "https://b.example/"]))
    assert %{urls: ["https://a.example/", "https://b.example/"], active: 0} = Session.load_disk()

    # Out-of-range active clamps to 0 rather than pointing past the list.
    File.write!(path, JSON.encode!(%{urls: ["https://a.example/"], active: 7}))
    assert %{urls: ["https://a.example/"], active: 0} = Session.load_disk()
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

  describe "profiles (restore_plan/2)" do
    alias BowserBrain.Session

    test "the first default-profile tab loads into the existing window; the rest open with their profile" do
      entries = [
        %{url: "https://w.example/1", profile: "work"},
        %{url: "https://p.example/1", profile: "default"},
        %{url: "https://p.example/2", profile: "default"}
      ]

      assert {"https://p.example/1", rest, 0} = Session.restore_plan(entries, 1)
      assert Enum.map(rest, & &1.url) == ["https://w.example/1", "https://p.example/2"]
      # active = the work tab: it is the FIRST open_tab -> 1 tab_opened to wait for
      assert {_, _, 1} = Session.restore_plan(entries, 0)
      # active = second default tab: second open_tab
      assert {_, _, 2} = Session.restore_plan(entries, 2)
    end

    test "no default tab: the blank first webview stays and everything opens by profile" do
      entries = [%{url: "https://w.example/1", profile: "work"}, %{url: "https://w.example/2", profile: "work"}]
      assert {nil, ^entries, 2} = Session.restore_plan(entries, 1)
    end

    test "legacy bare urls are default-profile entries" do
      assert {"https://a", [%{url: "https://b", profile: "default"}], 1} =
               Session.restore_plan(["https://a", "https://b"], 1)
    end
  end
end
