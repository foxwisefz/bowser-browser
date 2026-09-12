defmodule BowserBrain.AppModsTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{AppMods, AgentPort}
  @id "com.foxwiseai.bowser.site.0123456789abcdef"
  @other "com.foxwiseai.bowser.site.fedcba9876543210"

  setup do
    root = Path.join(System.tmp_dir!(), "bowser-appmods-#{System.unique_integer([:positive])}")

    old =
      for key <- [:app_mods_dir, :site_apps_dir],
          into: %{},
          do: {key, Application.get_env(:bowser_brain, key)}

    Application.put_env(:bowser_brain, :app_mods_dir, Path.join(root, "mods"))
    Application.put_env(:bowser_brain, :site_apps_dir, Path.join(root, "apps"))

    for id <- [@id, @other] do
      dir = Path.join([root, "apps", String.replace_prefix(id, "com.foxwiseai.bowser.site.", "")])
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
    root = Path.join(System.tmp_dir!(), "mcp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    executable = Path.expand("../../shell/.build/debug/BowserRuntimeTool", __DIR__)

    assert File.regular?(executable),
           "Build native helper: swift build --package-path shell --product BowserRuntimeTool"

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :line,
        ifaddr: {:local, Path.join(root, "agent.sock")},
        reuseaddr: true
      ])

    on_exit(fn -> :gen_tcp.close(listener) end)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        args: ["bowser-mcp-bridge"],
        env: [
          {~c"BOWSER_HOME", String.to_charlist(root)},
          {~c"BOWSER_SITE_APP_ID", String.to_charlist(@id)}
        ]
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    Port.command(
      port,
      JSON.encode!(%{
        jsonrpc: "2.0",
        id: 17,
        method: "tools/call",
        params: %{name: "list_tabs", arguments: %{site_app: @other}}
      }) <> "\n"
    )

    {:ok, connection} = :gen_tcp.accept(listener, 3_000)

    try do
      assert {:ok, request} = :gen_tcp.recv(connection, 0, 3_000)
      assert %{"tool" => "list_tabs", "args" => %{"site_app" => @id}} = JSON.decode!(request)
      :ok = :gen_tcp.send(connection, "{\"ok\":true}\n")
      assert_receive {^port, {:data, {:eol, reply}}}, 3_000

      assert %{"id" => 17, "result" => %{"isError" => false, "content" => [%{"text" => text}]}} =
               JSON.decode!(reply)

      assert JSON.decode!(text) == %{"ok" => true}
    after
      :gen_tcp.close(connection)
    end
  end
end
