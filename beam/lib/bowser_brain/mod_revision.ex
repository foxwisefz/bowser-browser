defmodule BowserBrain.ModRevision do
  @moduledoc "Write-ahead file revisions for ModSmith. File restoration never promises to undo website actions or mod data."

  def id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  def path,
    do:
      Application.get_env(
        :bowser_brain,
        :modsmith_workspace_path,
        Path.join(BowserBrain.Paths.home(), "modsmith-workspace.json")
      )

  def empty, do: %{"projects" => [], "selected" => %{}}

  def load do
    case File.read(path()) do
      {:error, :enoent} ->
        empty()

      {:ok, raw} ->
        case JSON.decode(raw) do
          {:ok, %{"projects" => projects, "selected" => selected} = data}
          when is_list(projects) and is_map(selected) ->
            data

          _ ->
            raise "Cannot read ModSmith history; original file has been preserved"
        end

      {:error, reason} ->
        raise "Cannot read ModSmith history: #{inspect(reason)}"
    end
  end

  def save(data) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path() <> ".tmp", JSON.encode!(data))
    File.rename!(path() <> ".tmp", path())
    data
  end

  def new_revision(request),
    do: %{
      "id" => id(),
      "request" => request,
      "files" => %{},
      "status" => "working",
      "at" => System.system_time(:millisecond)
    }

  def allowed?(path) when is_binary(path) do
    Regex.match?(
      ~r/^(assets\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-][A-Za-z0-9._-]*\.svg|sites\/[A-Za-z0-9_-][A-Za-z0-9._-]*\/[A-Za-z0-9_-][A-Za-z0-9._-]*\.(css|js)|mods\/[A-Za-z0-9_-][A-Za-z0-9._-]*\.ex|app-mods\/com\.gezim\.bowser\.site\.[0-9a-f]{16}\/[A-Za-z0-9_-][A-Za-z0-9._-]*\.(css|js))(\.off)?$/,
      path
    ) and not String.contains?(path, "..")
  end

  def allowed?(_), do: false

  def absolute(path) do
    unless allowed?(path), do: raise(ArgumentError, "Invalid mod path: #{inspect(path)}")
    root = BowserBrain.Paths.home()
    # Refuse symlinks anywhere below the state root for both writes and restoration.
    Enum.reduce(Path.split(path), root, fn part, parent ->
      next = Path.join(parent, part)

      case File.lstat(next) do
        {:ok, %{type: :symlink}} -> raise ArgumentError, "Mod path is a symlink: #{path}"
        _ -> next
      end
    end)
  end

  def read(path) do
    case File.read(absolute(path)) do
      {:ok, content} -> content
      {:error, :enoent} -> nil
      {:error, reason} -> raise "Cannot read #{path}: #{inspect(reason)}"
    end
  end

  def actual_path(path) do
    if not String.ends_with?(path, ".off") and read(path) == nil and read(path <> ".off") != nil,
      do: path <> ".off",
      else: path
  end

  def capture(revision, path, content) do
    absolute(path)

    before =
      case revision["files"][path] do
        nil ->
          read(path)

        existing ->
          if read(path) not in [existing["before"], existing["after"]],
            do: raise("#{path} changed outside this run. Your edit has been preserved.")

          existing["before"]
      end

    put_in(revision, ["files", path], %{"before" => before, "after" => content})
  end

  def write(path, nil) do
    case File.rm(absolute(path)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise "Cannot remove #{path}: #{inspect(reason)}"
    end
  end

  def write(path, content) do
    target = absolute(path)
    File.mkdir_p!(Path.dirname(target))
    temporary = target <> "." <> id() <> ".tmp"
    File.write!(temporary, content, [:exclusive])
    File.rename!(temporary, target)
  end

  def changed?(revision),
    do: Enum.any?(revision["files"], fn {_, f} -> f["before"] != f["after"] end)

  def restore(revision) do
    # Check EVERY path before changing any. Never erase an external edit.
    conflict =
      Enum.find(revision["files"], fn {path, file} ->
        read(path) not in [file["before"], file["after"]]
      end)

    if conflict do
      {:error,
       "#{elem(conflict, 0)} changed outside this revision. Restore stopped to preserve those edits."}
    else
      originals = Map.new(revision["files"], fn {path, _} -> {path, read(path)} end)

      try do
        Enum.each(revision["files"], fn {path, file} -> write(path, file["before"]) end)
        :ok
      rescue
        error ->
          Enum.each(originals, fn {path, content} -> write(path, content) end)
          {:error, Exception.message(error)}
      end
    end
  end
end
