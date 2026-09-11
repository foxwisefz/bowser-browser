defmodule BowserBrain.ModCatalog do
  @moduledoc """
  What customizations already exist, in a form an agent can reason about.

  ModSmith used to hand Claude only the site payloads for the current host —
  never the ~/.bowser/mods/*.ex catalog — so "make the dock tabs bigger"
  could not find edge_dock_tabs.ex and either failed or rewrote from scratch.
  The catalog is one line per file (path, on/off, host scope, what it does);
  `read/2` fetches full source on demand via the read_mod agent tool.

  Pure and directory-parametrized so it runs under tests on tmp dirs.
  """

  @type entry :: %{path: String.t(), enabled: boolean, host: String.t() | nil, about: String.t()}

  def mods_dir, do: Path.join(BowserBrain.Paths.home(), "mods")
  def sites_dir, do: Path.join(BowserBrain.Paths.home(), "sites")

  @doc "Every mod and site payload, enabled or `.off`, sorted by path."
  @spec catalog(String.t(), String.t()) :: [entry]
  def catalog(mods \\ mods_dir(), sites \\ sites_dir()) do
    mod_entries =
      for file <- Path.wildcard(Path.join(mods, "*.ex{,.off}")),
          not BowserBrain.LegacyMods.superseded?(file),
          do: entry("mods/" <> Path.basename(file), file)

    site_entries =
      for file <- Path.wildcard(Path.join(sites, "*/*.{css,js}{,.off}")) do
        host = file |> Path.dirname() |> Path.basename()
        entry("sites/#{host}/" <> Path.basename(file), file, host)
      end

    Enum.sort_by(mod_entries ++ site_entries, & &1.path)
  end

  @doc "The catalog as prompt text: one line per file, `None.` when empty."
  def summary(mods \\ mods_dir(), sites \\ sites_dir()) do
    case catalog(mods, sites) do
      [] ->
        "None."

      entries ->
        Enum.map_join(entries, "\n", fn e ->
          state = if e.enabled, do: "on ", else: "OFF"
          scope = if e.host, do: e.host, else: "global"
          "- #{e.path} [#{state}] (#{scope}) — #{e.about}"
        end)
    end
  end

  @doc """
  Full source of one catalog path (`mods/x.ex` or `sites/host/x.css`). A
  request for the enabled name also finds the `.off` twin, so the agent can
  read a disabled mod it was asked to fix.
  """
  def read(path, mods \\ mods_dir(), sites \\ sites_dir()) do
    with :ok <- safe_path(path),
         file when is_binary(file) <- resolve(path, mods, sites) do
      File.read(file)
    else
      nil -> {:error, :enoent}
      error -> error
    end
  end

  @doc "Strip the `.off` suffix, used to show a stable name for a disabled file."
  def display(path), do: String.replace_suffix(path, ".off", "")

  @doc """
  One line describing a source file: the first @moduledoc line, else the
  first leading `#`/`/*`/`//` comment line, else the first non-blank line.
  """
  def about(source) when is_binary(source) do
    doc =
      case Regex.run(~r/@moduledoc\s+"""\s*\n\s*([^\n]+)/, source) do
        [_, line] -> line
        _ -> nil
      end

    comment =
      source
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&String.contains?(&1, "bowser-profile:"))
      |> Enum.find(&String.match?(&1, ~r{^(#|//|/\*)}))
      |> case do
        nil -> nil
        line -> line |> String.replace(~r{^(#+|//|/\*+)\s*}, "") |> String.replace(~r{\s*\*/$}, "")
      end

    first =
      source |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.find("", &(&1 != ""))

    (doc || comment || first) |> String.slice(0, 100)
  end

  # -- private ---------------------------------------------------------------

  defp entry(path, file, host \\ nil) do
    source = File.read!(file)

    %{
      path: path,
      enabled: not String.ends_with?(file, ".off"),
      profile: BowserBrain.ModScope.source_profile(source),
      host: host || host_of_source(source),
      about: about(source)
    }
  end

  defp host_of_source(source) do
    case Regex.run(~r/use\s+BowserBrain\.Mod\s*,\s*host:\s*"([^"]+)"/, source) do
      [_, host] -> host
      _ -> nil
    end
  end

  defp safe_path(path) do
    cond do
      String.contains?(path, "..") -> {:error, :traversal}
      String.starts_with?(path, "mods/") or String.starts_with?(path, "sites/") -> :ok
      true -> {:error, :outside}
    end
  end

  defp resolve(path, mods, sites) do
    base =
      case path do
        "mods/" <> rest -> Path.join(mods, rest)
        "sites/" <> rest -> Path.join(sites, rest)
      end

    Enum.find([base, base <> ".off"], &File.exists?/1)
  end
end
