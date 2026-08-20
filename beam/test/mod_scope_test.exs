defmodule BowserBrain.ModScopeTest do
  # Host scoping for page-specific mods (bowser-browser-7md): a mod
  # declaring `use BowserBrain.Mod, host: "x.com"` must never see events
  # from tabs on other sites.
  use ExUnit.Case, async: false

  alias BowserBrain.Mod

  test "no host declared: nothing is scoped out" do
    refute Mod.scoped_out?(%{"event" => "url_changed", "url" => "https://a.example/"}, nil)
  end

  test "events carrying a url are matched directly, subdomains included" do
    refute Mod.scoped_out?(%{"event" => "url_changed", "url" => "https://x.com/home"}, "x.com")
    refute Mod.scoped_out?(%{"event" => "url_changed", "url" => "https://api.x.com/x"}, "x.com")
    assert Mod.scoped_out?(%{"event" => "url_changed", "url" => "https://a.example/"}, "x.com")
  end

  test "events without a webview always pass (hello, omnibar, chrome, surface)" do
    refute Mod.scoped_out?(%{"event" => "hello"}, "x.com")
    refute Mod.scoped_out?(%{"event" => "omnibar_command", "text" => "go"}, "x.com")
    refute Mod.scoped_out?(%{"event" => "chrome_click", "id" => "b"}, "x.com")
  end

  test "webview events consult the session mirror; unknown webviews pass" do
    # Hermetic app: Session runs with an empty mirror — unknown url must
    # PASS, or brand-new tabs (tab_opened before url_changed) break mods.
    refute Mod.scoped_out?(%{"event" => "load_status", "webview" => 999_999}, "x.com")
  end

  test "a host-scoped module drops foreign events before handle_event" do
    defmodule ScopedProbe do
      use BowserBrain.Mod, host: "x.com"

      def init_mod(_opts), do: %{seen: []}

      def handle_event(%{"event" => "url_changed", "url" => url}, state),
        do: %{state | seen: [url | state.seen]}

      def handle_event(_event, state), do: state
    end

    {:ok, pid} = GenServer.start_link(ScopedProbe, [])
    send(pid, {:browser_event, %{"event" => "url_changed", "webview" => 1, "url" => "https://x.com/a"}})
    send(pid, {:browser_event, %{"event" => "url_changed", "webview" => 2, "url" => "https://other.example/"}})
    assert %{seen: ["https://x.com/a"]} = :sys.get_state(pid)
    GenServer.stop(pid)
  end
end
