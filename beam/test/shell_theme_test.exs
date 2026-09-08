defmodule ShellThemeTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{ShellTheme, Chrome}

  setup do
    on_exit(fn ->
      # Synchronize monitor cleanup before the next test.
      ShellTheme.current()
    end)

    :ok
  end

  test "validates colors and bounded dimensions without accepting unknown keys" do
    assert {:ok, %{"background" => "#0047AB"}} = ShellTheme.validate(%{background: "#0047AB"})

    for invalid <- [
          %{background: "red"},
          %{title_size: 100},
          %{corner_radius: -1},
          %{show_navigation: "yes"},
          %{button_style: "unknown"},
          %{css: "body{}"}
        ] do
      assert {:error, :invalid_theme} = ShellTheme.validate(invalid)
    end
  end

  test "invalid update preserves the current theme and reset clears the owner" do
    assert :ok = Chrome.set_theme(%{background: "#0047AB"})
    assert {:error, :invalid_theme} = Chrome.set_theme(%{background: "invalid"})
    assert Chrome.theme() == %{"background" => "#0047AB"}
    assert :ok = Chrome.reset_theme()
    assert Chrome.theme() == %{}
  end

  test "stopping a winning mod restores previous theme, then native defaults" do
    assert :ok = Chrome.set_theme(%{background: "#0047AB"})
    parent = self()

    pid =
      spawn(fn ->
        Chrome.set_theme(%{background: "#112233"})
        send(parent, :applied)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :applied
    assert Chrome.theme() == %{"background" => "#112233"}
    send(pid, :stop)
    wait_for(%{"background" => "#0047AB"})
    Chrome.reset_theme()
    assert Chrome.theme() == %{}
  end

  test "releasing theme ownership for hot reload prevents stale styles after undo" do
    Chrome.set_theme(%{background: "#0047AB"})
    ShellTheme.release(self())
    assert Chrome.theme() == %{}
  end

  test "engine reconnect keeps the effective theme and exposes it to verification tool" do
    Chrome.set_theme(%{background: "#0047AB", show_navigation: true})
    send(ShellTheme, {:browser_event, %{"event" => "hello"}})

    assert %{ok: true, theme: %{"background" => "#0047AB", "show_navigation" => true}} =
             BowserBrain.AgentPort.dispatch(%{"tool" => "shell_theme"})

    Chrome.reset_theme()
  end

  defp wait_for(theme, attempts \\ 50)
  defp wait_for(theme, 0), do: assert(Chrome.theme() == theme)

  defp wait_for(theme, attempts) do
    if Chrome.theme() != theme do
      Process.sleep(10)
      wait_for(theme, attempts - 1)
    end
  end
end
