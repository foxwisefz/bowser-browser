defmodule BowserBrain.IconJobs do
  @moduledoc "Supervised, bounded icon jobs. Native pixel work runs only in a disposable OS process."
  use GenServer
  alias BowserBrain.{Bridge, Paths}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true),
      do: Registry.register(BowserBrain.Events, :browser_event, nil)

    {:ok,
     %{
       active: %{},
       waiting: %{},
       latest: %{},
       notify: Keyword.get(opts, :notify, &Bridge.cast_msg/1),
       root: Keyword.get(opts, :root, Paths.home()),
       worker: Keyword.get(opts, :worker, Paths.icon_worker()),
       timeout: Keyword.get(opts, :timeout, 5_000),
       supervisor: Keyword.get(opts, :supervisor, BowserBrain.IconTasks)
     }}
  end

  @impl true
  def handle_info({:browser_event, %{"event" => "hello"}}, state) do
    state.notify.(%{op: "request_icons"})
    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "icon_candidates"} = event}, state) do
    with %{"generation" => generation, "url" => url, "webview" => webview, "profile" => profile} <-
           event,
         true <-
           is_binary(generation) and byte_size(generation) <= 64 and is_integer(webview) and
             webview > 0,
         true <- is_binary(profile) and is_binary(url),
         %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) <-
           URI.parse(url),
         [_ | _] = candidates <- rank(Map.get(event, "candidates", [])) do
      target = {event["app"], webview}

      duplicate =
        Enum.any?(state.active, fn {_, job} ->
          job.target == target and job.event["generation"] == generation
        end)

      if duplicate do
        {:noreply, state}
      else
        job = %{target: target, event: Map.put(event, "candidates", candidates)}

        waiting =
          if map_size(state.waiting) < 16 or Map.has_key?(state.waiting, target),
            do: Map.put(state.waiting, target, job),
            else: state.waiting

        state = %{state | waiting: waiting, latest: Map.put(state.latest, target, generation)}
        {:noreply, pump(state)}
      end
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {job, active} = Map.pop(state.active, ref)

    if job && state.latest[job.target] == job.event["generation"] do
      case result do
        {:ok, paths} ->
          cache_app(paths, job.event, state.root)

          state.notify.(
            Map.merge(paths, %{
              op: "icon_ready",
              webview: job.event["webview"],
              generation: job.event["generation"],
              url: job.event["url"],
              app: job.event["app"]
            })
          )

          state.notify.(%{op: "refresh_app_icons"})

        # Keep the last usable icon; no browser restart or fatal UI error.
        {:error, _} ->
          :ok
      end
    end

    {:noreply, pump(%{state | active: active})}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: {:noreply, pump(%{state | active: Map.delete(state.active, ref)})}

  def handle_info(_, state), do: {:noreply, state}

  defp pump(state) when map_size(state.active) >= 2 or map_size(state.waiting) == 0, do: state

  defp pump(state) do
    {target, job} = Enum.at(state.waiting, 0)
    opts = Map.take(state, [:worker, :root, :timeout])
    task = Task.Supervisor.async_nolink(state.supervisor, fn -> run_job(job.event, opts) end)

    pump(%{
      state
      | active: Map.put(state.active, task.ref, job),
        waiting: Map.delete(state.waiting, target)
    })
  end

  def rank(candidates) when is_list(candidates) do
    candidates
    |> Enum.take(10)
    |> Enum.filter(fn
      %{"width" => w, "height" => h} = c ->
        is_integer(w) and is_integer(h) and w in 1..512 and h in 1..512 and
          ((is_binary(c["png"]) and byte_size(c["png"]) <= 1_500_000) or valid_url?(c["url"]))

      _ ->
        false
    end)
    |> Enum.sort_by(fn c -> {min(c["width"], c["height"]), c["app"] == true} end, :desc)
    |> Enum.take(3)
  end

  def rank(_), do: []

  def run_job(event, opts) do
    Enum.reduce_while(rank(event["candidates"]), {:error, :no_icon}, fn candidate, _ ->
      case candidate_data(candidate, opts) do
        {:ok, data} when byte_size(data) <= 4_000_000 ->
          case render(data, opts) do
            {:ok, _} = result -> {:halt, result}
            error -> {:cont, error}
          end

        _ ->
          {:cont, {:error, :invalid_data}}
      end
    end)
  end

  defp valid_url?(url) when is_binary(url) and byte_size(url) <= 4096 do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp valid_url?(_), do: false

  defp candidate_data(%{"png" => png}, _), do: Base.decode64(png)

  defp candidate_data(%{"url" => url}, opts) do
    directory = Path.join(opts.root, "favicons/downloads")
    File.mkdir_p!(directory)
    input = Path.join(directory, Integer.to_string(System.unique_integer([:positive])))

    try do
      with :ok <-
             run_worker(
               "/usr/bin/curl",
               [
                 "--fail",
                 "--silent",
                 "--location",
                 "--proto",
                 "=http,https",
                 "--proto-redir",
                 "=http,https",
                 "--max-time",
                 "3",
                 "--max-filesize",
                 "4000000",
                 "--output",
                 input,
                 url
               ],
               4_000
             ),
           {:ok, %{size: size}} when size <= 4_000_000 <- File.stat(input),
           {:ok, data} <- File.read(input),
           do: {:ok, data}
    after
      File.rm(input)
    end
  end

  defp render(data, opts) do
    key = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
    directory = Path.join(opts.root, "favicons/tiles-v2")
    path = Path.join(directory, key <> ".png")
    icns = Path.join(directory, key <> ".icns")

    if File.regular?(path) and File.regular?(icns) do
      {:ok, %{path: path, icns: icns, attempts: 0}}
    else
      File.mkdir_p!(directory)
      temp = Path.join(directory, ".job-#{System.unique_integer([:positive])}")
      File.mkdir_p!(temp)

      try do
        input = Path.join(temp, "input")
        output = Path.join(temp, "icon.png")
        bundle_icon = Path.join(temp, "icon.icns")
        File.write!(input, data)
        # One retry for transient worker failures. A bad candidate then yields
        # to the next candidate; nothing gets linked to the browser or Bridge.
        result =
          Enum.reduce_while(1..2, {:error, :worker}, fn attempt, _ ->
            case run_worker(opts.worker, [input, output, bundle_icon], opts.timeout) do
              :ok -> {:halt, {:ok, attempt}}
              error -> {:cont, error}
            end
          end)

        with {:ok, attempts} <- result,
             {:ok, <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>} <- File.read(output),
             {:ok, <<"icns", _::binary>>} <- File.read(bundle_icon),
             :ok <- File.rename(output, path),
             :ok <- File.rename(bundle_icon, icns) do
          {:ok, %{path: path, icns: icns, attempts: attempts}}
        else
          _ -> {:error, :worker_failed}
        end
      after
        File.rm_rf(temp)
      end
    end
  rescue
    _ -> {:error, :io}
  end

  def run_worker(executable, args, timeout) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: Enum.map(args, &String.to_charlist/1)
      ])

    try do
      wait_worker(port, System.monotonic_time(:millisecond) + timeout)
    after
      if Port.info(port) do
        if {:os_pid, pid} = Port.info(port, :os_pid),
          do: System.cmd("/bin/kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)

        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end
      end
    end
  rescue
    _ -> {:error, :start_failed}
  end

  defp wait_worker(port, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, _}} -> {:error, :worker_exit}
      {^port, {:data, _}} -> wait_worker(port, deadline)
    after
      remaining -> {:error, :timeout}
    end
  end

  def icon_key(url, profile) do
    uri = URI.parse(url)
    origin = URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port})
    :crypto.hash(:sha256, profile <> "\n" <> origin) |> Base.encode16(case: :lower)
  end

  defp cache_app(paths, event, root) do
    directory = Path.join(root, "app-icons-v2")
    File.mkdir_p(directory)
    key = icon_key(event["url"], event["profile"])

    for {source, extension} <- [{paths.path, ".png"}, {paths.icns, ".icns"}] do
      destination = Path.join(directory, key <> extension)

      with {:ok, data} <- File.read(source),
           :ok <- File.write(destination <> ".new", data),
           do: File.rename(destination <> ".new", destination)
    end
  end
end
