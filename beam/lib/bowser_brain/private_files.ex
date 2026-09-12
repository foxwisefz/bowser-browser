defmodule BowserBrain.PrivateFiles do
  @moduledoc false

  # Socket parents must be private before bind, not merely after the socket
  # exists. Refuse symlinks rather than chmod a redirected directory.
  def directory!(path) do
    File.mkdir_p!(path)
    case File.lstat!(path) do
      %{type: :directory} -> File.chmod!(path, 0o700)
      _ -> raise ArgumentError, "private directory must be a real directory"
    end
    :ok
  end

  def read(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        with :ok <- File.chmod(path, 0o600), do: File.read(path)
      {:ok, _} -> {:error, :invalid_file_type}
      error -> error
    end
  end

  # The random staging directory is private before any secret bytes are
  # written. Rename publishes a complete 0600 file and replaces symlinks
  # rather than following them. Never chmod a generic parent (e.g. /tmp).
  def write!(path, contents) do
    parent = Path.dirname(path)
    File.mkdir_p!(parent)
    staging = Path.join(parent, ".bowser-private-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false))
    File.mkdir!(staging)
    try do
      File.chmod!(staging, 0o700)
      temporary = Path.join(staging, "data")
      File.write!(temporary, contents, [:exclusive])
      File.chmod!(temporary, 0o600)
      File.rename!(temporary, path)
    after
      File.rm_rf!(staging)
    end
    :ok
  end
end
