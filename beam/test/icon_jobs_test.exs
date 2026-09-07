defmodule BowserBrain.IconJobsTest do
  use ExUnit.Case, async: false
  alias BowserBrain.IconJobs

  setup do
    root = Path.join("/tmp", "bowser-icon-jobs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    tasks = start_supervised!({Task.Supervisor, []})
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, tasks: tasks}
  end

  defp worker(root, body) do
    path = Path.join(root, "worker")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp candidate(png, size \\ 64),
    do: %{"png" => Base.encode64(png), "width" => size, "height" => size}

  defp event(generation, candidates),
    do: %{
      "event" => "icon_candidates",
      "webview" => 1,
      "generation" => generation,
      "url" => "https://example.com/page",
      "profile" => "work",
      "candidates" => candidates
    }

  defp start_jobs(root, tasks, executable, extra \\ []) do
    parent = self()

    start_supervised!(
      {IconJobs,
       [
         name: :icon_job_test,
         subscribe: false,
         root: root,
         supervisor: tasks,
         worker: executable,
         notify: fn msg -> send(parent, msg) end
       ] ++ extra}
    )
  end

  test "ranking uses actual pixels, validates bounds and prefers app artwork on ties" do
    small = candidate("a", 32)
    big = candidate("b", 512)
    app = Map.put(candidate("c", 512), "app", true)
    assert IconJobs.rank([small, big, app, candidate("oversized", 999), %{}]) == [app, big, small]
  end

  test "worker crash is contained and later requests still succeed", %{root: root, tasks: tasks} do
    executable = worker(root, "kill -KILL \"$$\"\n")
    jobs = start_jobs(root, tasks, executable)
    send(jobs, {:browser_event, event("bad", [candidate("bad")])})
    wait_idle(jobs)
    assert Process.alive?(jobs)
    assert Process.alive?(tasks)
    refute_receive %{op: "icon_ready"}, 30

    worker(
      root,
      "printf '\\211PNG\\r\\n\\032\\nfixture' > \"$2\"\nprintf 'icnsfixture' > \"$3\"\n"
    )

    send(jobs, {:browser_event, event("good", [candidate("good")])})
    assert_receive %{op: "icon_ready", generation: "good", path: path}, 3000
    assert File.regular?(path)
    assert Process.alive?(jobs)
  end

  test "a stuck worker times out without taking down its coordinator", %{root: root, tasks: tasks} do
    executable = worker(root, "while :; do :; done\n")
    jobs = start_jobs(root, tasks, executable, timeout: 60)
    send(jobs, {:browser_event, event("hang", [candidate("hang")])})
    wait_idle(jobs)
    assert Process.alive?(jobs)
    refute_receive %{op: "icon_ready"}, 30
  end

  test "outdated generation cannot replace current icon", %{root: root, tasks: tasks} do
    executable =
      worker(
        root,
        "case \"$(cat \"$1\")\" in slow) sleep 0.2;; esac\nprintf '\\211PNG\\r\\n\\032\\nfixture' > \"$2\"\nprintf 'icnsfixture' > \"$3\"\n"
      )

    jobs = start_jobs(root, tasks, executable)
    send(jobs, {:browser_event, event("old", [candidate("slow")])})
    send(jobs, {:browser_event, event("new", [candidate("fast")])})
    assert_receive %{op: "icon_ready", generation: "new"}, 3000
    wait_idle(jobs)
    refute_receive %{op: "icon_ready", generation: "old"}, 30
  end

  test "cache hit never launches another worker and profiles stay separate", %{
    root: root,
    tasks: tasks
  } do
    executable =
      worker(
        root,
        "printf '\\211PNG\\r\\n\\032\\nfixture' > \"$2\"\nprintf 'icnsfixture' > \"$3\"\n"
      )

    jobs = start_jobs(root, tasks, executable)
    send(jobs, {:browser_event, event("first", [candidate("cached")])})
    assert_receive %{op: "icon_ready", attempts: 1}, 3000
    worker(root, "kill -KILL \"$$\"\n")
    send(jobs, {:browser_event, event("cached", [candidate("cached")])})
    assert_receive %{op: "icon_ready", attempts: 0}, 3000

    assert IconJobs.icon_key("https://example.com/page", "work") ==
             IconJobs.icon_key("https://example.com", "work")

    refute IconJobs.icon_key("https://example.com", "work") ==
             IconJobs.icon_key("https://example.com", "personal")
  end

  test "profile portrait participates in rendering and cache identity", %{root: root, tasks: tasks} do
    executable = worker(root, "printf '\\211PNG\\r\\n\\032\\nfixture' > \"$2\"\nprintf 'icns' > \"$3\"\ncat \"$4\" >> \"$3\"\n")
    jobs = start_jobs(root, tasks, executable)
    first = Map.put(event("bowser", [candidate("site")]), "profile_badge", Base.encode64("bowser"))
    send(jobs, {:browser_event, first})
    assert_receive %{op: "icon_ready", icns: a}, 3000
    assert File.read!(a) == "icnsbowser"
    second = Map.put(event("shy-guy", [candidate("site")]), "profile_badge", Base.encode64("shy-guy"))
    send(jobs, {:browser_event, second})
    assert_receive %{op: "icon_ready", icns: b, attempts: 1}, 3000
    assert File.read!(b) == "icnsshy-guy"
    refute a == b
  end

  defp wait_idle(jobs, tries \\ 100)
  defp wait_idle(_, 0), do: flunk("icon jobs failed to drain")

  defp wait_idle(jobs, tries) do
    state = :sys.get_state(jobs)

    if map_size(state.active) + map_size(state.waiting) > 0 do
      Process.sleep(10)
      wait_idle(jobs, tries - 1)
    end
  end
end
