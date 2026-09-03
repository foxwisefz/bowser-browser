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

  @poll_ms 1_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    # Off in hermetic tests (bowser-browser-is4).
    if Application.get_env(:bowser_brain, :watch_lib, true) do
      Code.put_compiler_option(:ignore_module_conflict, true)
      send(self(), {:scan, :baseline})
    end

    {:ok, %{mtimes: %{}}}
  end

  @impl true
  def handle_info({:scan, mode}, state) do
    mtimes =
      for path <- Path.wildcard(Path.join(BowserBrain.Paths.brain_lib(), "*.ex")), into: %{} do
        {path, File.stat!(path, time: :posix).mtime}
      end

    if mode != :baseline do
      compile_all(changed(state.mtimes, mtimes))
    end

    Process.send_after(self(), {:scan, :diff}, @poll_ms)
    {:noreply, %{state | mtimes: mtimes}}
  end

    def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Compile a batch of changed files, retrying the ones that fail after the
  rest succeed: two files changed together may depend on each other (a
  module importing a helper added to view.ex in the same edit), and map
  order is arbitrary. A file that still fails after the retry is logged and
  its old code keeps running. Returns `{compiled, failed}` paths. Public
  for tests.
  """
  def compile_all(paths) do
    {ok, failed} = compile_pass(paths)

    {ok2, failed2} =
      if failed != [] and ok != [] do
        compile_pass(Enum.map(failed, &elem(&1, 0)))
      else
        {[], failed}
      end

    for {path, error} <- failed2 do
      Logger.error(
        "libreload: #{Path.basename(path)} failed to compile — old code still running\n" <>
          Exception.format(:error, error)
      )
    end

    {ok ++ ok2, Enum.map(failed2, &elem(&1, 0))}
  end

  defp compile_pass(paths) do
    Enum.reduce(paths, {[], []}, fn path, {ok, failed} ->
      try do
        Code.compile_file(path)
        Logger.info("libreload: hot-swapped #{Path.basename(path)}")
        {ok ++ [path], failed}
      rescue
        error -> {ok, failed ++ [{path, error}]}
      end
    end)
  end

  @doc """
  Paths to recompile: every file whose mtime differs from the last scan —
  including files the last scan never saw. A brand-new lib file used to be
  silently skipped (the guard required a prior mtime), so a module added
  while the brain ran did not exist until a full restart (bowser-browser-y7g).
  Public for tests.
  """
  def changed(previous, current) do
    for {path, mtime} <- current, previous[path] != mtime, do: path
  end
end
