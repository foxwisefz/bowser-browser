defmodule BowserBrain.Loader do
  @moduledoc """
  The hot-reload loop: watches ~/.bowser/mods/*.ex (500ms mtime polling —
  no deps) and compiles changed files straight into the running VM.

  - New mod file        -> compiled, started under ModSupervisor
  - Edited mod file     -> recompiled; the running process picks up the new
                           code on its next event, state intact, no restart
  - Broken mod file     -> compile error logged, old code keeps running
  """
  use GenServer
  require Logger

  @poll_ms 500

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def mods_dir, do: Path.join(System.user_home!(), ".bowser/mods")

  @impl true
  def init(nil) do
    File.mkdir_p!(mods_dir())
    Code.put_compiler_option(:ignore_module_conflict, true)
    send(self(), :scan)
    {:ok, %{mtimes: %{}}}
  end

  @impl true
  def handle_info(:scan, state) do
    mtimes =
      for path <- Path.wildcard(Path.join(mods_dir(), "*.ex")), into: %{} do
        {path, File.stat!(path, time: :posix).mtime}
      end

    changed = for {path, mtime} <- mtimes, state.mtimes[path] != mtime, do: path
    Enum.each(changed, &load_file/1)

    Process.send_after(self(), :scan, @poll_ms)
    {:noreply, %{state | mtimes: mtimes}}
  end

  defp load_file(path) do
    Logger.info("loader: compiling #{Path.basename(path)}")

    try do
      for {module, _bytecode} <- Code.compile_file(path),
          function_exported?(module, :__bowser_mod__, 0) do
        case DynamicSupervisor.start_child(BowserBrain.ModSupervisor, {module, []}) do
          {:ok, _pid} ->
            Logger.info("loader: started mod #{inspect(module)}")

          {:error, {:already_started, _pid}} ->
            Logger.info("loader: hot-swapped mod #{inspect(module)}")

          {:error, reason} ->
            Logger.error("loader: mod #{inspect(module)} failed to start: #{inspect(reason)}")
        end
      end
    rescue
      error ->
        Logger.error(
          "loader: #{Path.basename(path)} failed to compile — old code still running\n" <>
            Exception.format(:error, error, __STACKTRACE__)
        )
    end
  end
end
