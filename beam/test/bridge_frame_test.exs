defmodule BowserBrain.BridgeFrameTest do
  use ExUnit.Case, async: true
  alias BowserBrain.Bridge

  test "packet4 requests and fragmented replies preserve JSON and correlation" do
    path = Path.join(System.tmp_dir!(), "frame-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: 4, active: false, ifaddr: {:local, path}])

    {:ok, peer} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: :raw, active: false])
    {:ok, sock} = :gen_tcp.accept(listener, 1_000)

    on_exit(fn ->
      for s <- [peer, sock, listener], do: :gen_tcp.close(s)
      File.rm(path)
    end)

    tag = make_ref()
    state = %{sock: sock, pending: %{}, next_id: 1}
    {:noreply, state} = Bridge.handle_call({:eval_js, 7, "'hello'", :isolated}, {self(), tag}, state)
    assert {:ok, <<size::32>>} = :gen_tcp.recv(peer, 4, 1_000)
    assert {:ok, bytes} = :gen_tcp.recv(peer, size, 1_000)
    assert %{"op" => "eval_js", "id" => 1, "webview" => 7, "world" => "isolated"} = JSON.decode!(bytes)
    reply = JSON.encode!(%{op: "js_result", id: 1, ok: true, value: "héllo"})
    frame = <<byte_size(reply)::32, reply::binary>>
    for <<byte <- frame>>, do: :gen_tcp.send(peer, <<byte>>)
    assert {:ok, payload} = :gen_tcp.recv(sock, 0, 1_000)
    {:noreply, state} = Bridge.handle_info({:tcp, sock, payload}, state)
    assert_receive {^tag, {:ok, "héllo"}}
    assert state.pending == %{}
    assert {:noreply, ^state} = Bridge.handle_info({:tcp, sock, "invalid JSON"}, state)
  end
end
