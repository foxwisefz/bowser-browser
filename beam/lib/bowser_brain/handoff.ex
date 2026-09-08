defmodule BowserBrain.Handoff do
  @moduledoc """
  Installed release handoff. Candidates boot without listeners, watchers or mods.
  State crosses VMs only at a quiescent boundary. Schema 1 requires data-only
  mod state and an explicit `handoff: true` contract: no untracked timers, tasks,
  ports or external processes. Restored mods skip init_mod and hello.
  Bump the schema when changing migrated core state incompatibly.
  """
  alias BowserBrain.{Bridge, Paths}
  @schema 1
  @core [BowserBrain.Loader, BowserBrain.SiteMods, BowserBrain.LibReloader,
         BowserBrain.Profiles, BowserBrain.Session, BowserBrain.UserContent,
         BowserBrain.Surface, BowserBrain.ModLog, BowserBrain.XFeed,
         BowserBrain.Settings, BowserBrain.ModSmith, BowserBrain.Store]
  def schema, do: @schema

  # Release eval warms all code/services without acquiring host authority.
  def run do
    dir = System.fetch_env!("BOWSER_RELAY_DIR")
    # BEAM is never allowed to outlive its owner, even if that owner is killed
    # during a freeze. The native app is not a child of either process.
    owner = System.fetch_env!("BOWSER_RELAY_PID")
    spawn(fn -> watch_owner(owner) end)
    System.put_env("BOWSER_NO_SPAWN", "1")
    Application.load(:bowser_brain)
    for key <- [:connect_bridge, :spawn_engine, :load_user_mods, :watch_lib, :watch_sites],
      do: Application.put_env(:bowser_brain, key, false)
    {:ok, _} = Application.ensure_all_started(:bowser_brain)
    Code.put_compiler_option(:ignore_module_conflict, true)
    for path <- Path.wildcard(Path.join(Paths.home(), "mods/*.ex")), do: Code.compile_file(path)
    path = Path.join(dir, "control.sock")
    File.rm(path)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: false,
      ifaddr: {:local, String.to_charlist(path)}])
    File.chmod!(path, 0o600)
    control_loop(listener, [])
  end

  defp watch_owner(pid) do
    Process.sleep(500)
    case System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} -> watch_owner(pid)
      _ -> System.halt(0)
    end
  end

  defp control_loop(listener, suspended) do
    {:ok, sock} = :gen_tcp.accept(listener)
    {reply, suspended} =
      try do
        {:ok, bytes} = :gen_tcp.recv(sock, 0, 5_000)
        command(JSON.decode!(bytes), suspended)
      rescue
        e -> {%{ok: false, error: Exception.message(e)}, suspended}
      catch
        kind, reason -> {%{ok: false, error: inspect({kind, reason})}, suspended}
      end
    :gen_tcp.send(sock, JSON.encode!(reply))
    :gen_tcp.close(sock)
    control_loop(listener, suspended)
  end
  defp command(%{"op" => "status"}, suspended) do
    session = :sys.get_state(BowserBrain.Session, 150)
    {%{ok: true, schema: @schema, pid: System.pid(),
       profiles: session.profiles, active: session.active,
       restoring: session.restore != nil}, suspended}
  end
  defp command(%{"op" => "preflight"}, []) do
    for {_, _, _, [module]} <- DynamicSupervisor.which_children(BowserBrain.ModSupervisor) do
      unless function_exported?(module, :__bowser_handoff__, 0) and module.__bowser_handoff__(),
        do: raise("#{inspect(module)} has not declared a safe handoff contract")
    end
    {%{ok: true}, []}
  end
  defp command(%{"op" => "start"}, []) do
    enable()
    {%{ok: true}, []}
  end
  defp command(%{"op" => "freeze"}, []) do
    Process.put(:handoff_suspended, [])
    try do
      mods = for {_, pid, _, [module]} <- DynamicSupervisor.which_children(BowserBrain.ModSupervisor), do: {module, pid}
      for {module, _} <- mods do
        unless function_exported?(module, :__bowser_handoff__, 0) and module.__bowser_handoff__(),
          do: raise("#{inspect(module)} has not declared a safe handoff contract")
      end
      for server <- [BowserBrain.AgentPort, BowserBrain.XServer], do: GenServer.call(server, :handoff_pause, 200)
      unless external_idle?(), do: raise("external request in progress")
      pairs = Enum.map(@core, &{&1, Process.whereis(&1)})
      for {_, pid} <- Enum.take(pairs, 3) ++ mods ++ Enum.drop(pairs, 3) ++ [{BowserBrain.IconJobs, Process.whereis(BowserBrain.IconJobs)}] do
        :ok = :sys.suspend(pid, 150)
        Process.put(:handoff_suspended, [pid | Process.get(:handoff_suspended)])
      end
      unless map_size(:sys.get_state(Bridge, 150).pending) == 0, do: raise("page request in flight")
      icon = :sys.get_state(BowserBrain.IconJobs, 150)
      unless map_size(icon.active) == 0 and map_size(icon.waiting) == 0 and Task.Supervisor.children(BowserBrain.IconTasks) == [], do: raise("icon job in flight")
      states = Map.new(pairs ++ mods, fn {module, pid} ->
        state = :sys.get_state(pid, 150)
        unless portable?(state), do: raise("#{inspect(module)} holds a live resource")
        {:messages, messages} = Process.info(pid, :messages)
        unless Enum.all?(messages, &poll_message?(module, &1)), do: raise("#{inspect(module)} has queued work")
        {module, state}
      end)
      session = states[BowserBrain.Session]
      unless session.restore == nil and not Map.get(session, :quitting, false), do: raise("session transition in progress")
      unless states[BowserBrain.ModSmith].busy == nil and not states[BowserBrain.XFeed].busy and not states[BowserBrain.XFeed].awaiting, do: raise("background request in progress")
      snapshot = %{schema: @schema, states: states, mods: Enum.map(mods, &elem(&1, 0)), mod_hashes: Map.new(mods, fn {m, _} -> {m, m.module_info(:md5)} end), icon_latest: icon.latest}
      bytes = :erlang.term_to_binary(snapshot, [:compressed])
      if byte_size(bytes) > 8_000_000, do: raise("checkpoint exceeds 8 MB")
      {%{ok: true, snapshot: Base.encode64(bytes)}, Process.get(:handoff_suspended)}
    rescue
      e -> thaw(); {%{ok: false, error: Exception.message(e)}, []}
    catch
      kind, reason -> thaw(); {%{ok: false, error: inspect({kind, reason})}, []}
    end
  end
  defp command(%{"op" => "restore", "snapshot" => encoded}, []) do
    bytes = Base.decode64!(encoded)
    if byte_size(bytes) > 8_000_000, do: raise("checkpoint too large")
    %{schema: @schema, states: states, mods: mods, mod_hashes: hashes, icon_latest: latest} = :erlang.binary_to_term(bytes, [:safe])
    unless Enum.all?(states, fn {_, s} -> portable?(s) end), do: raise("nonportable checkpoint")
    for module <- @core, do: :sys.replace_state(module, fn _ -> Map.fetch!(states, module) end)
    :sys.replace_state(BowserBrain.IconJobs, &%{&1 | latest: latest})
    Application.put_env(:bowser_brain, :handoff_mod_states, Map.take(states, mods))
    for module <- mods do
      true = module.__bowser_handoff__()
      true = module.module_info(:md5) == hashes[module]
      {:ok, _} = DynamicSupervisor.start_child(BowserBrain.ModSupervisor, {module, []})
    end
    Application.delete_env(:bowser_brain, :handoff_mod_states)
    send(Bridge, :connect)
    {%{ok: true}, []}
  end
  defp command(%{"op" => "commit"}, []) do
    enable(false)
    {%{ok: true}, []}
  end
  defp command(%{"op" => "resume"}, suspended) do
    Enum.each(suspended, &safe_resume/1)
    resume_listeners()
    {%{ok: true}, []}
  end
  defp command(_, suspended), do: {%{ok: false, error: "invalid phase"}, suspended}
  defp enable(first \\ true) do
    for key <- [:connect_bridge, :load_user_mods, :watch_sites], do: Application.put_env(:bowser_brain, key, true)
    if first, do: send(Bridge, :connect)
    send(BowserBrain.Loader, :scan)
    send(BowserBrain.SiteMods, {:scan, false})
    resume_listeners()
  end
  defp resume_listeners do
    for server <- [BowserBrain.AgentPort, BowserBrain.XServer], do: send(server, :listen)
  end
  defp thaw do
    Enum.each(Process.get(:handoff_suspended, []), &safe_resume/1)
    resume_listeners()
  end
  defp safe_resume(pid) do
    try do :sys.resume(pid, 100) catch :exit, _ -> :ok end
  end
  def portable?(x) when is_pid(x) or is_port(x) or is_reference(x) or is_function(x), do: false
  def portable?(x) when is_map(x), do: Enum.all?(Map.to_list(x), fn {k, v} -> portable?(k) and portable?(v) end)
  def portable?(x) when is_tuple(x), do: x |> Tuple.to_list() |> Enum.all?(&portable?/1)
  def portable?([]), do: true
  def portable?([h | t]), do: portable?(h) and portable?(t)
  def portable?(_), do: true
  defp poll_message?(BowserBrain.Loader, :scan), do: true
  defp poll_message?(BowserBrain.SiteMods, {:scan, _}), do: true
  defp poll_message?(BowserBrain.LibReloader, {:scan, _}), do: true
  defp poll_message?(_, _), do: false
  def external_task(fun) do
    parent = self()
    result = Task.start(fn -> Process.put(:bowser_external, true); send(parent, {:external_ready, self()}); fun.() end)
    case result do
      {:ok, pid} -> receive do {:external_ready, ^pid} -> result end
      other -> other
    end
  end
  defp external_idle? do
    not Enum.any?(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} -> Keyword.get(dict, :bowser_external, false)
        _ -> false
      end
    end)
  end
end
