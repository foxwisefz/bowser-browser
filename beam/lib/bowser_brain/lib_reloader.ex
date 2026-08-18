defmodule BowserBrain.LibReloader do
  @moduledoc """
  Ends the restart era for brain code: watches beam/lib/bowser_brain/*.ex
  and compiles changes straight into the running VM (the supervised version
  of the "medic" pattern). GenServers pick up new module code on their next
  message; state survives. Only supervision-tree SHAPE changes (new child
  specs) still need an iex restart.
  """
  use GenServer
  require Logger

  @dir "/Users/gezim/projects/bowser-browser/beam/lib/bowser_brain"
  @poll_ms 1_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Code.put_compiler_option(:ignore_module_conflict, true)
    send(self(), {:scan, :baseline})
    {:ok, %{mtimes: %{}}}
  end

  @impl true
  def handle_info({:scan, mode}, state) do
    mtimes =
      for path <- Path.wildcard(Path.join(@dir, "*.ex")), into: %{} do
        {path, File.stat!(path, time: :posix).mtime}
      end

    if mode != :baseline do
      for {path, mtime} <- mtimes, state.mtimes[path] != nil, state.mtimes[path] != mtime do
        try do
          Code.compile_file(path)
          Logger.info("libreload: hot-swapped #{Path.basename(path)}")
        rescue
          error ->
            Logger.error(
              "libreload: #{Path.basename(path)} failed to compile — old code still running\n" <>
                Exception.format(:error, error, __STACKTRACE__)
            )
        end
      end
    end

    Process.send_after(self(), {:scan, :diff}, @poll_ms)
    {:noreply, %{state | mtimes: mtimes}}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
