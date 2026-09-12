defmodule BowserBrain.Loader do
  @moduledoc """
  The hot-reload loop: watches ~/.bowser/mods/*.ex (500ms mtime polling —
  no deps) and compiles changed files straight into the running VM.

  - New mod file        -> compiled, started under ModSupervisor
  - Edited mod file     -> recompiled; the running process picks up the new
                           code on its next event, state intact, no restart
  - Broken mod file     -> compile error logged, old code keeps running
  - Deleted mod file    -> its process is stopped (deleting a mod is how the
                           owner kills it; it used to keep running until a
                           brain restart)
  """
  use GenServer
  require Logger

  @poll_ms 500

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def mods_dir, do: Path.join(BowserBrain.Paths.home(), "mods")

  @impl true
  def init(nil) do
    # Hermetic tests do not compile the owner's live mods (bowser-browser-is4).
    if Application.get_env(:bowser_brain, :load_user_mods, true) do
      File.mkdir_p!(mods_dir())
      Code.put_compiler_option(:ignore_module_conflict, true)
      send(self(), :scan)
    end

    {:ok, %{mtimes: %{}, modules: %{}}}
  end

  @impl true
  def handle_info(:scan, state) do
    mtimes =
      for path <- Path.wildcard(Path.join(mods_dir(), "*.ex")),
          into: %{} do
        {path, :crypto.hash(:sha256, File.read!(path))}
      end

    # path -> modules it declares, snapshotted while the file still exists so
    # a deleted file can still be mapped to the process to stop.
    modules = state.modules

    changed = for {path, mtime} <- mtimes, state.mtimes[path] != mtime, do: path
    Enum.each(changed, &load_file/1)
    modules = Enum.reduce(changed, modules, &Map.put(&2, &1, modules_in(&1)))

    gone = vanished(state.mtimes, mtimes)
    for path <- gone, module <- Map.get(modules, path, []), do: stop_module(module, path)

    if changed != [] or gone != [] do
      if pid = Process.whereis(BowserBrain.ModControls), do: send(pid, :catalog_changed)
    end
    Process.send_after(self(), :scan, @poll_ms)
    {:noreply, state |> Map.put(:mtimes, mtimes) |> Map.put(:modules, Map.drop(modules, gone))}
  end

  def load_now(path), do: GenServer.call(__MODULE__, {:load_now, path}, 15_000)

  @impl true
  def handle_call({:load_now, path}, _, state) do
    result = load_file(path)
    mtimes = Map.put(state.mtimes, path, :crypto.hash(:sha256, File.read!(path)))
    modules = Map.put(state.modules, path, modules_in(path))
    {:reply, result, state |> Map.put(:mtimes, mtimes) |> Map.put(:modules, modules)}
  end

  @doc "Paths the previous scan knew that no longer exist. Public for tests."
  def vanished(previous, current) do
    for {path, _} <- previous, not Map.has_key?(current, path), do: path
  end

  @doc "Modules a mod file declares, read from source (works before/without compiling). Public for tests."
  def modules_in(path) do
    case File.read(path) do
      {:ok, source} ->
        for [_, name] <- Regex.scan(~r/defmodule\s+([A-Za-z0-9_.]+)/, source),
            do: Module.concat([name])

      _ ->
        []
    end
  end

  defp stop_module(module, path) do
    case Registry.lookup(BowserBrain.ModRegistry, module) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(BowserBrain.ModSupervisor, pid)
        Logger.info("loader: #{Path.basename(path)} deleted — stopped #{inspect(module)}")

      _ ->
        :ok
    end
  end

  defp load_file(path) do
    Logger.info("loader: compiling #{Path.basename(path)}")

    try do
      profile = BowserBrain.ModScope.file_profile(path)
      for module <- modules_in(path), {pid, _} <- Registry.lookup(BowserBrain.ModRegistry, module) do
        if BowserBrain.ModScope.current(pid) not in [nil, profile],
          do: raise("Module #{inspect(module)} already belongs to another profile; choose a distinct module name")
      end
      results = for {module, _bytecode} <- Code.compile_file(path),
          function_exported?(module, :__bowser_mod__, 0) do
        case DynamicSupervisor.start_child(BowserBrain.ModSupervisor, {module, []}) do
          {:ok, _pid} ->
            Logger.info("loader: started mod #{inspect(module)}")
            %{module: inspect(module), status: "started"}

          {:error, {:already_started, pid}} ->
            Logger.info("loader: hot-swapped mod #{inspect(module)}")
            # An edit/Undo may remove theme code entirely. Drop the old
            # ownership before the new code reasserts its appearance.
            BowserBrain.ShellTheme.release(pid)
            BowserBrain.Toolbars.release(pid)
            # Let the mod re-assert injected content/chrome with its NEW code.
            send(pid, {:browser_event, %{"event" => "mod_reloaded"}})
            # A system message from this sender is processed after that event.
            try do
              :sys.get_state(pid, 2_000)
              %{module: inspect(module), status: "reloaded"}
            catch
              :exit, reason -> %{module: inspect(module), status: "failed", error: inspect(reason)}
            end

          {:error, reason} ->
            Logger.error("loader: mod #{inspect(module)} failed to start: #{inspect(reason)}")
            %{module: inspect(module), status: "failed", error: inspect(reason)}
        end
      end
      %{ok: results != [] and Enum.all?(results, &(&1.status != "failed")), modules: results}
    rescue
      error ->
        Logger.error(
          "loader: #{Path.basename(path)} failed to compile — old code still running\n" <>
            Exception.format(:error, error, __STACKTRACE__)
        )
        %{ok: false, error: Exception.message(error)}
    end
  end
end
