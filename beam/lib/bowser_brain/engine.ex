defmodule BowserBrain.Engine do
  @moduledoc """
  The engine as cattle (bowser-browser-7qq): the brain launches and
  supervises the Bowser binary itself. If the engine exits — crash, kill,
  or binary upgrade — it respawns within a second and Session restores the
  tabs. If a browser is already running (started by hand), we notice the
  bridge is connected and spawn nothing.

  Set BOWSER_NO_SPAWN=1 to disable supervision for a session.
  """
  use GenServer
  require Logger

  @check_ms 3_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    enabled =
      System.get_env("BOWSER_NO_SPAWN") == nil and
        Application.get_env(:bowser_brain, :spawn_engine, true)
    if enabled, do: Process.send_after(self(), :check, 1_500)
    {:ok, %{port: nil, os_pid: nil, enabled: enabled}}
  end

  @impl true
  def handle_info(:check, %{enabled: true} = state) do
    # Trust liveness, not bookkeeping: if the port is dead but we never got
    # exit_status (it happens — wrapper/pipe edge cases), self-heal here.
    port_alive = state.port != nil and Port.info(state.port) != nil
    state = if port_alive, do: state, else: %{state | port: nil, os_pid: nil}

    binary_newer = binary_mtime() > Map.get(state, :spawned_mtime, 0)

    state =
      case check_action(port_alive, binary_newer, BowserBrain.Bridge.connected?()) do
        :roll ->
          # Blue-green-lite (bowser-browser-ekd): an upgrade must never look
          # like a restart. Spawn the NEW instance first — its window appears
          # at the same saved frame wearing the freeze-frame, pixel-perfect
          # over the old one — then retire the old wrapper once the new
          # window has had time to paint. The old port's exit_status no
          # longer matches state.port, so it can't trigger a double respawn;
          # the bridge follows on its own (old connection dies -> reconnect
          # lands on the new listener -> hello -> restore).
          Logger.info("engine: binary updated on disk — blue-green roll")
          old_os_pid = state.os_pid
          state = spawn_engine(state)

          if old_os_pid != nil and state.os_pid != old_os_pid do
            Process.send_after(self(), {:retire, old_os_pid}, 1_200)
          end

          state

        :keep ->
          state

        :spawn ->
          Logger.info("engine: not running and bridge down — (re)spawning")
          spawn_engine(state)
      end

    Process.send_after(self(), :check, @check_ms)
    {:noreply, state}
  end

  # Clean exit = the user quit on purpose (Cmd-Q, closed last window).
  # Respawning would fight the user. Only dirty exits are crashes.
  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    Logger.info("engine: exited cleanly — user quit, not respawning")
    {:noreply, %{state | port: nil, os_pid: nil}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    delay =
      respawn_delay(Map.get(state, :last_spawn_at, 0), System.system_time(:millisecond))

    Logger.warning("engine: exited with status #{status} — respawning in #{delay}ms")
    Process.send_after(self(), :respawn, delay)
    {:noreply, %{state | port: nil, os_pid: nil}}
  end

  def handle_info(:respawn, %{enabled: true, port: nil} = state) do
    {:noreply, spawn_engine(state)}
  end

  # The old instance of a blue-green roll: its replacement is already on
  # screen, so this is a quiet retirement, not a death worth reacting to.
  def handle_info({:retire, os_pid}, state) do
    System.cmd("kill", roll_kill_args(os_pid))
    {:noreply, state}
  end

  # Engine output: surface our own diagnostics, drop the GL probing spam.
  def handle_info({_port, {:data, data}}, state) do
    for line <- String.split(data, "\n", trim: true),
        String.contains?(line, "Bowser:") do
      Logger.info("engine> #{line}")
    end

    {:noreply, state}
  end
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{os_pid: os_pid}) when is_integer(os_pid) do
    # BEAM going down shouldn't leave a zombie browser we spawned.
    System.cmd("kill", [Integer.to_string(os_pid)])
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @doc false
  # Pure decision for the liveness check. Public for tests.
  def check_action(port_alive?, binary_newer?, bridge_connected?) do
    cond do
      port_alive? and binary_newer? -> :roll
      port_alive? or bridge_connected? -> :keep
      true -> :spawn
    end
  end

  @doc false
  # The window-gone gap on a crash is respawn delay + app launch; the delay
  # part should be as close to zero as safety allows (bowser-browser-r48).
  # A spawn within the last 10s means we may be crash-looping — back off so
  # a broken binary can't respawn-storm the machine.
  def respawn_delay(last_spawn_at_ms, now_ms) do
    if now_ms - last_spawn_at_ms < 10_000, do: 2_000, else: 100
  end

  @doc false
  # os_pid is the WRAPPER's pid, and its trap only runs on catchable
  # signals: TERM forwards to the browser child and the wrapper exits with
  # its status, closing the port. SIGKILL here orphans the browser and the
  # watcher — they keep the port pipe open, no exit_status ever arrives,
  # and the roll loops on a dead pid forever (bowser-browser-p7l).
  def roll_kill_args(os_pid), do: ["-TERM", Integer.to_string(os_pid)]

  defp engine_path do
    Application.get_env(:bowser_brain, :engine_path, BowserBrain.Paths.engine_binary())
  end

  defp binary_mtime do
    case File.stat(engine_path(), time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  defp spawn_engine(state) do
    path = engine_path()

    if File.exists?(path) do
      Logger.info("engine: spawning #{path}")

      # Via the wrapper shim: the browser dies with the BEAM even on hard
      # abort (Ctrl-C x2), when terminate/2 never runs.
      port =
        Port.open(
          {:spawn_executable, BowserBrain.Paths.engine_wrapper()},
          [:binary, :exit_status, :stderr_to_stdout, args: [path]]
        )

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      state
      |> Map.put(:port, port)
      |> Map.put(:os_pid, os_pid)
      |> Map.put(:spawned_mtime, binary_mtime())
      |> Map.put(:last_spawn_at, System.system_time(:millisecond))
    else
      Logger.error("engine: binary not found at #{path} — run swift build")
      state
    end
  end
end
