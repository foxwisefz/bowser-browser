defmodule BowserBrain.EngineWrapperTest do
  use ExUnit.Case, async: true

  test "killed wrapper and browser cannot leave watcher holding the output pipe" do
    root = Path.join("/tmp", "wrapper-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    pidfile = Path.join(root, "child.pid")
    wrapper = Path.expand("../../bin/engine-wrapper", __DIR__)

    port =
      Port.open({:spawn_executable, wrapper}, [
        :binary,
        :exit_status,
        :eof,
        args: ["/bin/sh", "-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "fixture", pidfile]
      ])

    {:os_pid, wrapper_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
      System.cmd("/bin/kill", ["-KILL", to_string(wrapper_pid)], stderr_to_stdout: true)

      if File.exists?(pidfile) do
        System.cmd("/bin/kill", ["-KILL", String.trim(File.read!(pidfile))],
          stderr_to_stdout: true
        )
      end

      File.rm_rf!(root)
    end)

    wait_file(pidfile, 100)
    child_pid = String.trim(File.read!(pidfile))
    # Leave stdin open: an orphaned watcher must not hold the OUTPUT pipe.
    {_, 0} = System.cmd("/bin/kill", ["-KILL", to_string(wrapper_pid), child_pid])
    assert_receive {^port, :eof}, 2_000
  end

  defp wait_file(_, 0), do: flunk("fixture child did not start")

  defp wait_file(path, tries) do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_file(path, tries - 1)
        )
  end
end
