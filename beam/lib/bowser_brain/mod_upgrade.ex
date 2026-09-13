defmodule BowserBrain.ModUpgrade do
  @moduledoc """
  Compile and validate in a disposable BEAM peer before activating any bytecode.
  Running mod mailboxes are quiesced only for migration and atomic activation.
  Migration callbacks must be pure: the peer does not boot browser services.
  This is failure isolation, not an OS sandbox for accepted privileged Elixir.
  """
  @timeout 5_000

  def load(path) do
    root = to_string(:code.root_dir())
    boot = Path.join([root, "releases", to_string(Application.spec(:bowser_brain, :vsn)), "start_clean"])
    boot_args = if File.regular?(boot <> ".boot"), do: [~c"-boot", String.to_charlist(boot), ~c"-boot_var", ~c"RELEASE_LIB", String.to_charlist(Path.join(root, "lib"))], else: []
    args = [~c"+S", ~c"2"] ++ boot_args ++ Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    {:ok, peer, _} = :peer.start_link(%{connection: :standard_io, args: args, wait_boot: @timeout, env: [{~c"ERL_CRASH_DUMP", ~c"/dev/null"}]})
    try do
      {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir], @timeout)
      candidates = :peer.call(peer, Code, :compile_file, [path], @timeout)
      if candidates == [], do: raise("source defines no modules")
      mods = for {module, _} <- candidates,
        :peer.call(peer, :erlang, :function_exported, [module, :__bowser_mod__, 0]), do: module
      if mods == [], do: raise("source defines no mods")
      running = for module <- mods, {pid, _} <- Registry.lookup(BowserBrain.ModRegistry, module), do: {module, pid}
      transact(peer, path, candidates, running)
      mods
    after
      :peer.stop(peer)
    end
  end

  defp transact(peer, path, candidates, running) do
    # Track each successful suspension so a later timeout cannot strand it.
    key = {__MODULE__, :suspended}
    Process.put(key, [])
    try do
      originals = for {module, pid} <- running do
        :ok = :sys.suspend(pid, @timeout)
        Process.put(key, [pid | Process.get(key)])
        state = :sys.get_state(pid, @timeout)
        unless portable?(state), do: raise("#{inspect(module)} state contains runtime handles; move them outside migratable state")
        version = if function_exported?(module, :state_version, 0), do: module.state_version(), else: 0
        {module, pid, version, state}
      end
      prepared = for {module, pid, version, state} <- originals do
        migrated = :peer.call(peer, __MODULE__, :prepare, [module, version, state], @timeout)
        {pid, migrated}
      end
      # atomic_load never kills a process to purge old code. Refuse generations
      # whose old-code users have not retired before touching their state.
      for {module, _} <- candidates do
        unless :code.soft_purge(module), do: raise("#{inspect(module)} still has old-code users")
      end
      try do
        for {pid, state} <- prepared, do: :sys.replace_state(pid, fn _ -> state end, @timeout)
        :ok = :code.atomic_load(Enum.map(candidates, fn {module, binary} -> {module, String.to_charlist(path), binary} end))
      rescue
        error ->
          for {_, pid, _, state} <- originals, do: :sys.replace_state(pid, fn _ -> state end, @timeout)
          reraise error, __STACKTRACE__
      catch
        kind, error ->
          for {_, pid, _, state} <- originals, do: :sys.replace_state(pid, fn _ -> state end, @timeout)
          :erlang.raise(kind, error, __STACKTRACE__)
      end
    after
      for pid <- Process.delete(key) || [] do
        try do :sys.resume(pid, @timeout) catch :exit, _ -> :ok end
      end
    end
  end

  @doc false
  def prepare(module, old_version, state) do
    new_version = module.state_version()
    unless is_integer(new_version) and new_version >= 0, do: raise("state_version must be a nonnegative integer")
    case module.migrate_state(old_version, state) do
      {:ok, migrated} ->
        unless portable?(migrated), do: raise("migration returned runtime handles")
        unless module.validate_state(migrated) == :ok, do: raise("state validation rejected migration")
        migrated
      {:error, reason} -> raise("state migration rejected: #{inspect(reason)}")
      _ -> raise("migrate_state/2 must return {:ok, state} or {:error, reason}")
    end
  end

  def portable?(x) when is_atom(x) or is_number(x) or is_binary(x), do: true
  def portable?([]), do: true
  def portable?([h | t]), do: portable?(h) and portable?(t)
  def portable?(x) when is_tuple(x), do: x |> Tuple.to_list() |> Enum.all?(&portable?/1)
  def portable?(x) when is_map(x), do: Enum.all?(x, fn {k, v} -> portable?(k) and portable?(v) end)
  def portable?(_), do: false
end
