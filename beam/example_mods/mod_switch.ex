# Mod visibility + kill switches (bowser-browser-eef): `:mods` (or View →
# Mods) shows everything running against the CURRENT page — this host's
# site payloads and the global OTP mods — each row a one-click toggle.
# Off is the `.off` rename convention: SiteMods stops injecting a renamed
# payload within a second, and a disabled mod's process is terminated (the
# Loader restarts it when the file gets its name back). State survives
# restarts because it IS the filesystem.
defmodule ModSwitchMod do
  use BowserBrain.Mod

  import BowserBrain.View

  alias BowserBrain.{Chrome, Surface}

  def init_mod(_opts) do
    assert_chrome()
    # info: which rows have their (i) description expanded.
    %{active: 0, urls: %{}, info: MapSet.new()}
  end

  def handle_event(%{"event" => "hello"} = hello, state) do
    assert_chrome()
    %{state | active: Map.get(hello, "active", state.active)}
  end

  def handle_event(%{"event" => "tab_activated", "webview" => wv}, state) do
    %{state | active: wv}
  end

  def handle_event(%{"event" => "url_changed", "webview" => wv, "url" => url}, state) do
    %{state | urls: Map.put(state.urls, wv, url)}
  end

  def handle_event(%{"event" => "omnibar_command", "text" => "mods"}, state), do: render(state)
  def handle_event(%{"event" => "chrome_click", "id" => "mods"}, state), do: render(state)

  def handle_event(
        %{"event" => "surface", "surface" => "mods", "id" => "toggle", "value" => value},
        state
      ) do
    case parse_toggle(value) do
      {:site, host, name} ->
        dir = Path.join([System.user_home!(), ".bowser/sites", host])
        File.rename(Path.join(dir, name), Path.join(dir, toggle_path(name)))

      {:mod, name} ->
        dir = Path.join(System.user_home!(), ".bowser/mods")
        path = Path.join(dir, name)

        if enabled?(name) do
          # Terminate the running process too — the rename alone only
          # prevents future starts.
          with {:ok, source} <- File.read(path),
               modname when is_binary(modname) <- modname(source),
               [{pid, _}] <- Registry.lookup(BowserBrain.ModRegistry, Module.concat([modname])) do
            DynamicSupervisor.terminate_child(BowserBrain.ModSupervisor, pid)
          end
        end

        File.rename(path, Path.join(dir, toggle_path(name)))

      :error ->
        :ok
    end

    # Give SiteMods/Loader a beat to react, then re-render the truth.
    Process.send_after(self(), :rerender, 800)
    state
  end

  # ⓘ click: expand/collapse this row's description (bowser-browser-ft0
  # refinement — compact rows, info on demand).
  def handle_event(
        %{"event" => "surface", "surface" => "mods", "id" => "info", "value" => key},
        state
      ) do
    expanded = expanded(state)

    info =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    render(Map.put(state, :info, info))
  end

  def handle_event(_event, state), do: state

  def handle_info(:rerender, state) do
    {:noreply, render(state)}
  end

  def handle_info(other, state), do: super(other, state)

  # -- pure helpers (public for tests) ---------------------------------------

  @doc "The defmodule name inside mod source, or nil."
  def modname(source) do
    case Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)/, source) do
      [_, name] -> name
      _ -> nil
    end
  end

  @doc "a.css <-> a.css.off"
  def toggle_path(name) do
    if String.ends_with?(name, ".off"),
      do: String.replace_suffix(name, ".off", ""),
      else: name <> ".off"
  end

  def enabled?(name), do: not String.ends_with?(name, ".off")

  @doc """
  One-line description from a file's leading comment — Elixir `#`, JS `//`,
  or CSS `/* */` — nil when the file starts with code (bowser-browser-ft0).
  """
  def describe_source(source) do
    source
    |> String.split("\n", parts: 6)
    |> Enum.find_value(fn line ->
      case Regex.run(~r{^\s*(?:#|//|/\*)\s*(.+?)\s*(?:\*/)?\s*$}, line) do
        [_, text] when text != "" -> String.slice(text, 0, 60)
        _ -> nil
      end
    end)
  end

  @doc "The host: a mod declared in `use BowserBrain.Mod, host: ...`, or nil."
  def host_of_source(source) do
    case Regex.run(~r/use\s+BowserBrain\.Mod\s*,\s*host:\s*"([^"]+)"/, source) do
      [_, host] -> host
      _ -> nil
    end
  end

  @doc "Button payload round-trip: site|host|file or mod|file."
  def parse_toggle("site|" <> rest) do
    case String.split(rest, "|", parts: 2) do
      [host, name] -> {:site, host, name}
      _ -> :error
    end
  end

  def parse_toggle("mod|" <> name), do: {:mod, name}
  def parse_toggle(_), do: :error

  # -- rendering --------------------------------------------------------------

  defp assert_chrome do
    Chrome.register_command("mods", "What's modding this page — toggle on/off")
    Chrome.add_menu_item("mods", "Mods")
  end

  defp host_of(state) do
    url = state.urls[state.active] || ""
    URI.parse(url).host
  end

  defp render(state) do
    host = host_of(state)

    sites_dir = host && Path.join([System.user_home!(), ".bowser/sites", host])

    site_rows =
      case sites_dir && File.ls(sites_dir) do
        {:ok, names} ->
          for name <- Enum.sort(names),
              Path.extname(display(name)) in [".css", ".js"] do
            info = describe_file(Path.join(sites_dir, name)) || "site payload"
            row(dot(enabled?(name)) <> " " <> display(name), "site|#{host}|#{name}", info, state)
          end

        _ ->
          []
      end

    mods_dir = Path.join(System.user_home!(), ".bowser/mods")

    mod_rows =
      case File.ls(mods_dir) do
        {:ok, names} ->
          for name <- Enum.sort(names),
              String.ends_with?(name, ".ex") or String.ends_with?(name, ".ex.off"),
              not String.starts_with?(name, "zz_") do
            source = File.read!(Path.join(mods_dir, name))
            scope = host_of_source(source)

            status =
              cond do
                not enabled?(name) -> nil
                running?(source) -> nil
                true -> "STOPPED"
              end

            info =
              [scope, status, describe_source(source) || "mod"]
              |> Enum.reject(&is_nil/1)
              |> Enum.join(" · ")

            row(dot(enabled?(name)) <> " " <> display(name), "mod|#{name}", info, state)
          end

        _ ->
          []
      end

    Surface.show(
      :mods,
      vstack(
        [text("Mods", style: :title)] ++
          [text("This page#{if host, do: " — #{host}", else: ""}", style: :caption)] ++
          (site_rows == [] && [text("no site payloads", style: :caption)] || site_rows) ++
          [divider(), text("Global mods", style: :caption)] ++
          mod_rows ++
          [divider(), text("click to toggle · off = renamed .off", style: :caption)]
      ),
      title: "Mods",
      anchor: :right_of_main,
      width: 260
    )

    state
  end

  # A freshly hot-swapped process still carries the previous code's state
  # shape; reaching for state.info crashed and ATE the owner's click.
  # Tolerate any shape instead (the crash-restart heals state, but nothing
  # should be lost in the meantime).
  defp expanded(state), do: Map.get(state, :info) || MapSet.new()

  # Compact by default: toggle + ⓘ side by side; the description appears
  # under the row only while its ⓘ is expanded.
  defp row(label, payload, info, state) do
    head =
      hstack([
        button(label, event: "toggle", payload: payload),
        button("ⓘ", event: "info", payload: payload)
      ])

    if MapSet.member?(expanded(state), payload) do
      vstack([head, text(String.slice(info, 0, 90), style: :caption)])
    else
      head
    end
  end

  defp describe_file(path) do
    case File.read(path) do
      {:ok, source} -> describe_source(source)
      _ -> nil
    end
  end

  # Is the process for this mod source actually alive? An enabled file with
  # a dead process means it crashed past the restart budget.
  defp running?(source) do
    case modname(source) do
      nil -> false
      name -> Registry.lookup(BowserBrain.ModRegistry, Module.concat([name])) != []
    end
  end

  defp dot(true), do: "●"
  defp dot(false), do: "○"
  defp display(name), do: String.replace_suffix(name, ".off", "")
end
