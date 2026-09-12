defmodule BowserBrain.Handoff do
  @moduledoc """
  Installed release handoff. Candidates boot without listeners, watchers or mods.
  State crosses VMs only at a quiescent boundary. Schema 5 migrates symbolic theme/toolbar owners and requires data-only
  mod state and an explicit `handoff: true` contract: no untracked timers, tasks,
  ports or external processes. Restored mods skip init_mod and hello.
  Bump the schema when changing migrated core state incompatibly.
  """
  alias BowserBrain.{Bridge, Paths}
  @schema 5
  @core [BowserBrain.Loader, BowserBrain.SiteMods, BowserBrain.LibReloader,
         BowserBrain.Profiles, BowserBrain.Session, BowserBrain.UserContent,
         BowserBrain.Surface, BowserBrain.ModLog,
         BowserBrain.Settings, BowserBrain.ModWorkshop,
         BowserBrain.ShellTheme, BowserBrain.Toolbars, BowserBrain.Store,
         BowserBrain.TabDeck, BowserBrain.ModControls, BowserBrain.PanelMenu]
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
    # Core views may not render during candidate startup. Load the release's
    # modules now so their literal atoms exist before safe checkpoint decoding.
    for module <- Application.spec(:bowser_brain, :modules), do: Code.ensure_loaded!(module)
    Code.put_compiler_option(:ignore_module_conflict, true)
    for path <- Path.wildcard(Path.join(Paths.home(), "mods/*.ex")),
        do: Code.compile_file(path)
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
       restoring: session.restore != nil,
       engine_build: Map.get(:sys.get_state(Bridge, 150), :engine_build),
       core: %{
         tab_deck: :sys.get_state(BowserBrain.TabDeck, 150),
         panel_menu: :sys.get_state(BowserBrain.PanelMenu, 150),
         mod_controls_active: :sys.get_state(BowserBrain.ModControls, 150).active
       }}, suspended}
  end
  defp command(%{"op" => "preflight"}, []) do
    modules = for {_, _, _, [module]} <- DynamicSupervisor.which_children(BowserBrain.ModSupervisor), do: module
    require_contracts!(modules)
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
      require_contracts!(Enum.map(mods, &elem(&1, 0)))
      GenServer.call(BowserBrain.AgentPort, :handoff_pause, 200)
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
        state = checkpoint_state(module, :sys.get_state(pid, 150), Map.new(pairs ++ mods, fn {m, p} -> {p, m} end))
        unless portable?(state), do: raise("#{inspect(module)} holds a live resource")
        {:messages, messages} = Process.info(pid, :messages)
        unless Enum.all?(messages, &poll_message?(module, &1)), do: raise("#{inspect(module)} has queued work")
        {module, state}
      end)
      session = states[BowserBrain.Session]
      unless session.restore == nil and not Map.get(session, :quitting, false), do: raise("session transition in progress")
      unless states[BowserBrain.ModWorkshop].run == nil, do: raise("background request in progress")
      snapshot = %{schema: @schema, states: states, mods: Enum.map(mods, &elem(&1, 0)), mod_hashes: Map.new(mods, fn {m, _} -> {m, m.module_info(:md5)} end), icon_latest: icon.latest, engine_identity: Map.get(:sys.get_state(Bridge, 150), :engine_hello, %{})}
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
    # One restore attempt per disposable candidate bounds atom admission across
    # failures as well as successes. The host discards rejected candidates.
    if Process.get(:handoff_restore_attempted), do: raise("candidate restore already attempted")
    Process.put(:handoff_restore_attempted, true)
    if byte_size(encoded) > 10_666_668, do: raise("checkpoint too large")
    bytes = Base.decode64!(encoded)
    %{schema: @schema, states: states, mods: mods, mod_hashes: hashes, icon_latest: latest} = snapshot = BowserBrain.HandoffCheckpoint.decode!(bytes)
    unless Enum.all?(states, fn {_, s} -> portable?(s) end), do: raise("nonportable checkpoint")
    for module <- @core -- [BowserBrain.ShellTheme, BowserBrain.Toolbars],
      do: :sys.replace_state(module, fn _ -> Map.fetch!(states, module) end)
    :sys.replace_state(BowserBrain.IconJobs, &%{&1 | latest: latest})
    Application.put_env(:bowser_brain, :handoff_mod_states, Map.take(states, mods))
    for module <- mods do
      true = module.__bowser_handoff__()
      true = module.module_info(:md5) == hashes[module]
      {:ok, _} = DynamicSupervisor.start_child(BowserBrain.ModSupervisor, {module, []})
    end
    Application.delete_env(:bowser_brain, :handoff_mod_states)
    owners = Map.new(@core, &{&1, Process.whereis(&1)}) |> Map.merge(Map.new(mods, fn module ->
      [{pid, _}] = Registry.lookup(BowserBrain.ModRegistry, module)
      {module, pid}
    end))
    for module <- [BowserBrain.ShellTheme, BowserBrain.Toolbars],
      do: GenServer.call(module, {:handoff_restore, Map.fetch!(states, module), owners})
    GenServer.call(Bridge, {:restore_engine_identity, Map.get(snapshot, :engine_identity, %{})})
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
    send(BowserBrain.AgentPort, :listen)
  end
  defp thaw do
    Enum.each(Process.get(:handoff_suspended, []), &safe_resume/1)
    resume_listeners()
  end
  defp safe_resume(pid) do
    try do :sys.resume(pid, 100) catch :exit, _ -> :ok end
  end
  @doc false
  def incompatible_mods(modules) do
    Enum.reject(modules, fn module ->
      function_exported?(module, :__bowser_handoff__, 0) and module.__bowser_handoff__()
    end) |> Enum.sort()
  end
  defp require_contracts!(modules) do
    case incompatible_mods(modules) do
      [] -> :ok
      blocked -> raise("mods have not declared a safe handoff contract: #{Enum.map_join(blocked, ", ", &inspect/1)}")
    end
  end

  @doc false
  def checkpoint_state(module, entries, owners)
      when module in [BowserBrain.ShellTheme, BowserBrain.Toolbars] do
    Enum.map(entries, fn {pid, _monitor, payload} ->
      # Unregistered workers are not transferable owners. Fail before authority
      # changes instead of silently dropping their native UI.
      {Map.fetch!(owners, pid), payload}
    end)
  end
  def checkpoint_state(_, state, _owners), do: state

  @doc false
  def restore_owned_entries(entries, owners) do
    resolved = Enum.map(entries, fn {owner, payload} ->
      pid = Map.fetch!(owners, owner)
      unless is_pid(pid) and Process.alive?(pid), do: raise("handoff owner is unavailable")
      {pid, payload}
    end)
    Enum.map(resolved, fn {pid, payload} -> {pid, Process.monitor(pid), payload} end)
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
