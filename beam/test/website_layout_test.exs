defmodule BowserBrain.WebsiteLayoutTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{Surface, Bridge, AgentPort}

  test "layout API sends correlated native commands and returns tab IDs" do
    path = Path.join(System.tmp_dir!(), "layout-#{System.unique_integer([:positive])}.sock")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, ifaddr: {:local, path}])
    {:ok, peer} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: 4, active: false])
    {:ok, sock} = :gen_tcp.accept(listener, 1_000)
    previous = :sys.get_state(Bridge)
    :sys.replace_state(Bridge, &Map.put(&1, :sock, sock))
    on_exit(fn ->
      :sys.replace_state(Bridge, fn _ -> previous end)
      for s <- [peer, sock, listener], do: :gen_tcp.close(s)
      File.rm(path)
    end)
    owner = self()
    worker = Task.async(fn ->
      for action <- ["create_tab", "set", "get", "reset"] do
        {:ok, frame} = :gen_tcp.recv(peer, 0, 1_000)
        request = JSON.decode!(frame)
        send(owner, {:request, request})
        assert request["action"] == action
        send(Bridge, {:tcp, sock, JSON.encode!(%{op: "js_result", id: request["id"], ok: true,
          value: %{created: 32, panes: [31, 32]}})})
      end
    end)
    assert {:ok, %{"created" => 32}} = Surface.create_tab(31, "https://example.test/")
    assert_receive {:request, %{"action" => "create_tab", "webview" => 31, "profile" => "default", "url" => "https://example.test/"}}
    assert {:ok, _} = Surface.layout_tabs(31, [31, 32], axis: :vertical, weights: [0.3, 0.7])
    assert_receive {:request, %{"op" => "website_layout", "axis" => "vertical", "tabs" => [31, 32], "weights" => [0.3, 0.7]}}
    assert %{"ok" => true} = AgentPort.dispatch(%{"tool" => "website_layout", "args" => %{"webview" => 31, "action" => "get", "profile" => "injected"}})
    assert_receive {:request, %{"action" => "get", "profile" => "default"}}
    assert {:ok, _} = Surface.reset_layout(31)
    assert_receive {:request, %{"action" => "reset"}}
    Task.await(worker)
  end

  test "layout primitives reject invalid and foreign-profile targets" do
    assert {:error, :invalid_webview} = Surface.tab_layout(0)
    assert {:error, :invalid_url} = Surface.create_tab(31, nil)
    assert {:error, :invalid_layout} = Surface.layout_tabs(31, nil)
    assert {:error, :invalid_layout} = Surface.layout_tabs(31, [31, 31])
    assert {:error, :invalid_layout} = Surface.layout_tabs(31, [31, 32], weights: [0, 1])
    assert {:error, :invalid_layout} = Surface.layout_tabs(31, [31, 32], axis: :diagonal)
    Process.put(:bowser_profile, "work")
    assert {:error, :wrong_profile} = Surface.create_tab(31, "https://example.test/")
    assert {:error, :wrong_profile} = Surface.layout_tabs(31, [31, 32])
  end
end
