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
  @respawn_delay_ms 500
  @default_path "/Users/gezim/projects/bowser-browser/shell/.build/debug/Bowser"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    enabled = System.get_env("BOWSER_NO_SPAWN") == nil
    if enabled, do: Process.send_after(self(), :check, 1_500)
    {:ok, %{port: nil, os_pid: nil, enabled: enabled}}
  end

  @impl true
  def handle_info(:check, %{enabled: true} = state) do
    state =
      if BowserBrain.Bridge.connected?() or state.port != nil do
        state
      else
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
    Logger.warning("engine: exited with status #{status} — respawning")
    Process.send_after(self(), :respawn, @respawn_delay_ms)
    {:noreply, %{state | port: nil, os_pid: nil}}
  end

  def handle_info(:respawn, %{enabled: true, port: nil} = state) do
    {:noreply, spawn_engine(state)}
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

  defp spawn_engine(state) do
    path = Application.get_env(:bowser_brain, :engine_path, @default_path)

    if File.exists?(path) do
      Logger.info("engine: spawning #{path}")
      port = Port.open({:spawn_executable, path}, [:binary, :exit_status, :stderr_to_stdout])

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      %{state | port: port, os_pid: os_pid}
    else
      Logger.error("engine: binary not found at #{path} — run swift build")
      state
    end
  end
end
