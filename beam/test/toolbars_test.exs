defmodule ToolbarsTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{Toolbars, Chrome}

  test "bars replace in place, validate dimensions, and are removed on owner exit" do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Chrome.put_toolbar("status", %{t: "text", text: "Ready"}, edge: :bottom, size: 28)
        :ok = Chrome.put_toolbar("status", %{t: "text", text: "Updated"}, edge: :bottom, size: 32)
        send(parent, :ready)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :ready
    assert [%{id: "status", size: 32}] = Toolbars.list()
    assert {:error, :invalid_toolbar} = Chrome.put_toolbar("invalid", %{}, size: 999)
    send(pid, :stop)
    await_empty()
  end

  test "hot reload release removes bars and reconnect preserves definitions" do
    Chrome.put_toolbar("left", %{t: "text", text: "Tools"}, edge: :left, size: 100)
    send(Toolbars, {:browser_event, %{"event" => "hello"}})
    assert [%{edge: "left"}] = Toolbars.list()
    Toolbars.release(self())
    assert [] = Toolbars.list()
  end

  test "same id shadows another owner and removing it restores the older bar" do
    parent = self()

    pid =
      spawn(fn ->
        Chrome.put_toolbar("status", %{t: "text", text: "original"}, [])
        send(parent, :ready)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :ready
    Chrome.put_toolbar("status", %{t: "text", text: "override"}, [])
    assert [%{view: %{text: "override"}}] = Toolbars.list()
    Chrome.remove_toolbar("status")
    assert [%{view: %{text: "original"}}] = Toolbars.list()
    send(pid, :stop)
    await_empty()
  end

  test "full border validation accepts bounded style and rejects invalid input" do
    assert {:ok, _} =
             BowserBrain.ShellTheme.validate(%{
               window_border: "#808080",
               window_border_width: 4,
               window_border_style: "beveled"
             })

    assert {:error, _} = BowserBrain.ShellTheme.validate(%{window_border_width: 99})
  end

  defp await_empty(attempts \\ 100)
  defp await_empty(0), do: assert(Toolbars.list() == [])

  defp await_empty(n) do
    if Toolbars.list() != [] do
      Process.sleep(5)
      await_empty(n - 1)
    end
  end
end
