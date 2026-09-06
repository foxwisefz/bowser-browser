# One isolated coordinator for the signed-app smoke test; never boots the user's brain.
Code.require_file("../../lib/bowser_brain/paths.ex", __DIR__)
Code.require_file("../../lib/bowser_brain/icon_jobs.ex", __DIR__)
[request, output, root, worker] = System.argv()
parent = self()
{:ok, tasks} = Task.Supervisor.start_link()
# Kill only this disposable worker on its first attempt. The coordinator must
# recover without restarting itself or the browser that supplied the request.
stub = Path.join(root, "crash-first-worker")
quoted = "'" <> String.replace(worker, "'", "'\\''") <> "'"
File.mkdir_p!(root)

File.write!(
  stub,
  "#!/bin/sh\nif [ ! -e \"$1.crashed\" ]; then : > \"$1.crashed\"; kill -KILL \"$$\"; fi\nexec " <>
    quoted <> " \"$@\"\n"
)

File.chmod!(stub, 0o755)

{:ok, jobs} =
  BowserBrain.IconJobs.start_link(
    name: :smoke_icons,
    subscribe: false,
    root: root,
    worker: stub,
    supervisor: tasks,
    notify: fn reply -> send(parent, {:reply, reply}) end
  )

event = File.read!(request) |> JSON.decode!()
send(jobs, {:browser_event, event})

receive do
  {:reply, %{op: "icon_ready"} = reply} ->
    true = Process.alive?(jobs)
    true = Process.alive?(tasks)
    File.write!(output, JSON.encode!(reply))
after
  20_000 -> raise "icon coordinator failed to recover after worker crash"
end
