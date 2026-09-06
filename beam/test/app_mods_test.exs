defmodule BowserBrain.AppModsTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{AppMods, AgentPort}
  @id "com.gezim.bowser.site.0123456789abcdef"
  @other "com.gezim.bowser.site.fedcba9876543210"

  setup do
    root = Path.join(System.tmp_dir!(), "bowser-appmods-#{System.unique_integer([:positive])}")

    old =
      for key <- [:app_mods_dir, :site_apps_dir],
          into: %{},
          do: {key, Application.get_env(:bowser_brain, key)}

    Application.put_env(:bowser_brain, :app_mods_dir, Path.join(root, "mods"))
    Application.put_env(:bowser_brain, :site_apps_dir, Path.join(root, "apps"))

    for id <- [@id, @other] do
      dir = Path.join([root, "apps", String.replace_prefix(id, "com.gezim.bowser.site.", "")])
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "app.json"),
        JSON.encode!(%{identifier: id, url: "https://example.com/", profile: "default"})
      )
    end

    on_exit(fn ->
      File.rm_rf!(root)

      for {key, value} <- old do
        if value,
          do: Application.put_env(:bowser_brain, key, value),
          else: Application.delete_env(:bowser_brain, key)
      end
    end)

    %{app: %{"id" => @id, "url" => "https://example.com/"}}
  end

  test "tool writes and final envelopes share one app's private directory", %{app: app} do
    assert %{ok: true} =
             AgentPort.dispatch(%{
               "tool" => "put_payload",
               "args" => %{
                 "site_app" => @id,
                 "host" => "example.com",
                 "name" => "theme.css",
                 "content" => "body{color:red}"
               }
             })

    output =
      JSON.encode!(%{
        tier: "payload",
        summary: "larger text",
        files: [%{path: "sites/example.com/theme.css", content: "body{font-size:20px}"}]
      })

    assert {:ok, "larger text", ["app-mods/" <> _]} =
             AppMods.install_result({:output, output}, app)

    assert [{"theme.css", "body{font-size:20px}"}] = AppMods.payloads(@id)
    assert [] = AppMods.payloads(@other)

    assert %{ok: false} =
             AgentPort.dispatch(%{
               "tool" => "read_mod",
               "args" => %{"site_app" => @other, "path" => "app-mods/#{@id}/theme.css"}
             })
  end

  test "rejects global mutations, other hosts, traversal and BEAM code", %{app: app} do
    for tool <- ["put_mod", "store_put", "navigate", "set_setting"] do
      assert %{ok: false} = AgentPort.dispatch(%{"tool" => tool, "args" => %{"site_app" => @id}})
    end

    for path <- [
          "../escape.css",
          "/tmp/escape.js",
          "sites/other.com/style.css",
          "mods/evil.ex",
          "app-mods/#{@other}/style.css"
        ] do
      assert {:error, _} = AppMods.put(@id, path, "fixture")
    end

    assert {:error, _} = AppMods.put("unregistered", "style.css", "fixture")

    assert {:error, _} =
             AppMods.install_result(
               {:output,
                JSON.encode!(%{tier: "mod", files: [%{path: "mods/evil.ex", content: "fixture"}]})},
               app
             )

    assert [] = AppMods.payloads(@id)
  end

  test "prevalidates the entire envelope before writing any files", %{app: app} do
    output =
      JSON.encode!(%{
        files: [%{path: "good.css", content: "body{}"}, %{path: "../bad.js", content: "bad"}]
      })

    assert {:error, _} = AppMods.install_result({:output, output}, app)
    assert [] = AppMods.payloads(@id)
  end

  test "site evaluation keeps its app id and correlates its reply" do
    alias BowserBrain.Bridge
    path = "/tmp/bowser-bridge-#{System.unique_integer([:positive])}.sock"

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, String.to_charlist(path)},
        packet: 4,
        active: false
      ])

    {:ok, client} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, packet: 4, active: false])

    {:ok, peer} = :gen_tcp.accept(listener)

    on_exit(fn ->
      Enum.each([client, peer, listener], &:gen_tcp.close/1)
      File.rm(path)
    end)

    tag = make_ref()
    state = %{sock: client, next_id: 42, pending: %{}}

    assert {:noreply, pending} =
             Bridge.handle_call({:eval_site_js, @id, "document.title"}, {self(), tag}, state)

    assert {:ok, frame} = :gen_tcp.recv(peer, 0, 1000)

    assert %{"op" => "site_eval", "id" => 42, "app" => @id, "code" => "document.title"} =
             JSON.decode!(frame)

    reply = JSON.encode!(%{op: "js_result", id: 42, ok: true, value: "App title"})
    assert {:noreply, %{pending: empty}} = Bridge.handle_info({:tcp, client, reply}, pending)
    assert empty == %{}
    assert_receive {^tag, {:ok, "App title"}}
  end

  test "MCP bridge pins every tool call to its app even if arguments try to override it" do
    script = """
    import json, os, runpy, socket, tempfile, threading
    with tempfile.TemporaryDirectory(prefix='bowser-mcp-', dir='/tmp') as root:
        os.environ['BOWSER_HOME'] = root
        os.environ['BOWSER_SITE_APP_ID'] = '#{@id}'
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(root + '/agent.sock')
        listener.listen(1)
        received = []
        def serve():
            conn, _ = listener.accept()
            with conn:
                received.append(json.loads(conn.makefile('rb').readline()))
                conn.sendall(b'{"ok":true}' + bytes([10]))
        worker = threading.Thread(target=serve)
        worker.start()
        bridge = runpy.run_path('../bin/bowser-mcp-bridge', run_name='fixture')
        assert bridge['call_brain']('list_tabs', {'site_app': '#{@other}'}) == {'ok': True}
        worker.join(timeout=2)
        assert received[0]['args']['site_app'] == '#{@id}'
        listener.close()
    """

    assert {_, 0} = System.cmd("python3", ["-c", script], stderr_to_stdout: true)
  end
end
