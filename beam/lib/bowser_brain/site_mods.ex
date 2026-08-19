defmodule BowserBrain.SiteMods do
  @moduledoc """
  Per-origin persistent payloads (bowser-browser-uwo): plain files under
  ~/.bowser/sites/<host>/*.css|*.js, injected on every page of that host,
  forever — the "from now on" half of ModSmith, and hand-editable like
  everything else. 1s mtime polling; changes apply with a reload.
  """
  use GenServer
  require Logger

  alias BowserBrain.UserContent

  @poll_ms 1_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def sites_dir, do: Path.join(System.user_home!(), ".bowser/sites")

  @doc "Write a payload file (ModSmith calls this); applied within a second."
  def put(host, name, content) do
    dir = Path.join(sites_dir(), sanitize(host))
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, sanitize(name)), content)
  end

  def payloads_for(host) do
    dir = Path.join(sites_dir(), host)

    case File.ls(dir) do
      {:ok, names} ->
        for name <- Enum.sort(names), Path.extname(name) in [".css", ".js"] do
          {name, File.read!(Path.join(dir, name))}
        end

      _ ->
        []
    end
  end

  @impl true
  def init(nil) do
    # Off in hermetic tests (bowser-browser-is4).
    if Application.get_env(:bowser_brain, :watch_sites, true) do
      File.mkdir_p!(sites_dir())
      send(self(), {:scan, false})
    end

    {:ok, %{mtimes: %{}}}
  end

  @impl true
  def handle_info({:scan, reload_on_change}, state) do
    files = Path.wildcard(Path.join(sites_dir(), "*/*.{css,js}"))

    mtimes =
      for path <- files, into: %{} do
        {path, File.stat!(path, time: :posix).mtime}
      end

    if mtimes != state.mtimes do
      if map_size(state.mtimes) > 0 or not reload_on_change do
        Logger.info("sitemods: #{map_size(mtimes)} payload(s) across sites — applying")
      end

      UserContent.put_scripts(:site_mods, build_scripts(files),
        # First load registers before pages load; edits need a reload.
        reload: reload_on_change and map_size(state.mtimes) > 0
      )
    end

    Process.send_after(self(), {:scan, true}, @poll_ms)
    {:noreply, %{state | mtimes: mtimes}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp build_scripts(files) do
    for path <- Enum.sort(files) do
      host = path |> Path.dirname() |> Path.basename()
      content = File.read!(path)

      body =
        case Path.extname(path) do
          ".css" ->
            """
            var s = document.createElement("style");
            s.setAttribute("data-bowser-site", #{JSON.encode!(Path.basename(path))});
            s.textContent = #{JSON.encode!(content)};
            (document.head || document.documentElement).appendChild(s);
            """

          ".js" ->
            content
        end

      """
      (function () {
        var h = location.hostname;
        if (h !== #{JSON.encode!(host)} && !h.endsWith(#{JSON.encode!("." <> host)})) return;
        #{body}
      })();
      """
    end
  end

  defp sanitize(name), do: String.replace(name, ~r/[^A-Za-z0-9._-]/, "_")
end
