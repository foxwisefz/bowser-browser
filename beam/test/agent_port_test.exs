defmodule BowserBrain.AgentPortTest do
  use ExUnit.Case, async: true

  alias BowserBrain.AgentPort

  setup do
    path = Path.join(System.tmp_dir!(), "agentport-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, String.to_charlist(path)},
        packet: :line,
        active: false,
        reuseaddr: true
      ])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    {:ok, listener: listener, path: path}
  end

  test "ensure_acceptor starts one acceptor and is idempotent while it lives", %{listener: l} do
    {:noreply, state} = AgentPort.handle_info(:ensure_acceptor, %{listener: l})
    assert {pid, ref} = state.acceptor
    assert Process.alive?(pid)
    {:noreply, same} = AgentPort.handle_info(:ensure_acceptor, state)
    assert same.acceptor == {pid, ref}
  end

  test "a dead acceptor is restarted on DOWN and the new one serves", %{listener: l, path: path} do
    {:noreply, state} = AgentPort.handle_info(:ensure_acceptor, %{listener: l})
    {pid, ref} = state.acceptor
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    {:noreply, state} = AgentPort.handle_info({:DOWN, ref, :process, pid, :killed}, state)
    {new_pid, _} = state.acceptor
    assert new_pid != pid and Process.alive?(new_pid)

    {:ok, sock} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, packet: :line, active: false])

    :ok = :gen_tcp.send(sock, ~s({"tool":"nope"}\n))
    assert {:ok, line} = :gen_tcp.recv(sock, 0, 2_000)
    assert line =~ "unknown tool: nope"
  end

  test "large fragmented JSON is decoded once and the next request remains aligned", %{listener: l, path: path} do
    AgentPort.handle_info(:ensure_acceptor, %{listener: l})
    {:ok, sock} = :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, packet: :line, active: false])
    request = JSON.encode!(%{tool: "nope", args: %{content: String.duplicate("x", 100_000)}}) <> "\n"
    for chunk <- for(<<chunk::binary-size(1000) <- request>>, do: chunk), do: :gen_tcp.send(sock, chunk)
    remainder = rem(byte_size(request), 1000)
    :gen_tcp.send(sock, binary_part(request, byte_size(request) - remainder, remainder))
    assert {:ok, reply} = :gen_tcp.recv(sock, 0, 2_000)
    assert JSON.decode!(reply)["error"] == "unknown tool: nope"
    :gen_tcp.send(sock, ~s({"tool":"next"}\n))
    assert {:ok, reply} = :gen_tcp.recv(sock, 0, 2_000)
    assert JSON.decode!(reply)["error"] == "unknown tool: next"
    :gen_tcp.close(sock)
  end

  test "an unrelated DOWN is ignored", %{listener: l} do
    state = %{listener: l, acceptor: nil}
    assert {:noreply, ^state} = AgentPort.handle_info({:DOWN, make_ref(), :process, self(), :normal}, state)
  end
end
