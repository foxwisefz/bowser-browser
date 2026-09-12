defmodule BowserBrain.HandoffCheckpoint do
  @moduledoc false
  # Checkpoints come from the host's private, trusted generation channel. They
  # may contain runtime-created atoms absent from a fresh candidate. Validate
  # the complete data-only ETF before admitting a bounded atom vocabulary;
  # never compile disabled mods or decode executable ETF to warm that vocabulary.
  @limit 8_000_000
  @atoms 4096
  @new_atoms 1024
  @nodes 500_000

  def decode!(bytes) when byte_size(bytes) <= @limit do
    payload = expand(bytes)
    {<<>>, atoms, _} = scan(payload, MapSet.new(), @nodes, 0)
    missing = Enum.reject(atoms, fn name ->
      try do
        String.to_existing_atom(name)
        true
      rescue
        ArgumentError -> false
      end
    end)
    if length(missing) > @new_atoms, do: raise(ArgumentError, "too many new checkpoint atoms")
    Enum.each(missing, &String.to_atom/1)
    :erlang.binary_to_term(<<131, payload::binary>>, [:safe])
  end
  def decode!(_), do: raise(ArgumentError, "checkpoint exceeds 8 MB")

  defp expand(<<131, 80, size::32, compressed::binary>>) when size <= @limit do
    z = :zlib.open()
    try do
      :ok = :zlib.inflateInit(z)
      output = inflate(z, :zlib.safeInflate(z, compressed), [], 0, size)
      :ok = :zlib.inflateEnd(z)
      output
    after
      :zlib.close(z)
    end
  end
  defp expand(<<131, 80, _::binary>>), do: raise(ArgumentError, "checkpoint exceeds 8 MB")
  defp expand(<<131, payload::binary>>), do: payload
  defp expand(_), do: raise(ArgumentError, "invalid checkpoint encoding")

  defp inflate(z, {status, chunk}, chunks, count, expected) when status in [:continue, :finished] do
    count = count + IO.iodata_length(chunk)
    if count > expected, do: raise(ArgumentError, "checkpoint expanded size exceeds limit")
    chunks = [chunk | chunks]
    if status == :finished do
      if count != expected, do: raise(ArgumentError, "checkpoint expanded size mismatch")
      chunks |> Enum.reverse() |> IO.iodata_to_binary()
    else
      inflate(z, :zlib.safeInflate(z, []), chunks, count, expected)
    end
  end

  defp scan(_, _, budget, depth) when budget <= 0 or depth > 256,
    do: raise(ArgumentError, "checkpoint complexity exceeds limit")
  defp scan(<<97, _::8, rest::binary>>, a, n, _), do: {rest, a, n - 1}
  defp scan(<<98, _::32, rest::binary>>, a, n, _), do: {rest, a, n - 1}
  defp scan(<<70, _::64, rest::binary>>, a, n, _), do: {rest, a, n - 1}
  defp scan(<<99, _::binary-size(31), rest::binary>>, a, n, _), do: {rest, a, n - 1}
  defp scan(<<106, rest::binary>>, a, n, _), do: {rest, a, n - 1}
  defp scan(<<tag, size::16, name::binary-size(size), rest::binary>>, a, n, _) when tag in [100, 118],
    do: atom(rest, name, tag, a, n)
  defp scan(<<tag, size::8, name::binary-size(size), rest::binary>>, a, n, _) when tag in [115, 119],
    do: atom(rest, name, tag, a, n)
  defp scan(<<104, size::8, rest::binary>>, a, n, d), do: children(rest, size, a, n - 1, d + 1)
  defp scan(<<105, size::32, rest::binary>>, a, n, d), do: children(rest, size, a, n - 1, d + 1)
  defp scan(<<116, size::32, rest::binary>>, a, n, d), do: children(rest, size * 2, a, n - 1, d + 1)
  defp scan(<<108, size::32, rest::binary>>, a, n, d), do: children(rest, size + 1, a, n - 1, d + 1)
  defp scan(<<107, size::16, _::binary-size(size), rest::binary>>, a, n, _), do: {rest, a, n - 1}
  defp scan(<<109, size::32, _::binary-size(size), rest::binary>>, a, n, _), do: {rest, a, n - 1}
  defp scan(<<77, size::32, bits, _::binary-size(size), rest::binary>>, a, n, _) when size > 0 and bits in 1..8,
    do: {rest, a, n - 1}
  defp scan(<<110, size::8, sign, _::binary-size(size), rest::binary>>, a, n, _) when sign in [0, 1],
    do: {rest, a, n - 1}
  defp scan(<<111, size::32, sign, _::binary-size(size), rest::binary>>, a, n, _) when sign in [0, 1],
    do: {rest, a, n - 1}
  defp scan(_, _, _, _), do: raise(ArgumentError, "invalid or non-data checkpoint term")

  defp children(rest, 0, a, n, _), do: {rest, a, n}
  defp children(rest, count, a, n, d) when count <= n do
    {rest, a, n} = scan(rest, a, n, d)
    children(rest, count - 1, a, n, d)
  end
  defp children(_, _, _, _, _), do: raise(ArgumentError, "checkpoint complexity exceeds limit")

  defp atom(rest, name, tag, a, n) do
    name = if tag in [100, 115], do: :unicode.characters_to_binary(name, :latin1), else: name
    unless String.valid?(name) and length(String.to_charlist(name)) <= 255,
      do: raise(ArgumentError, "invalid checkpoint atom")
    a = MapSet.put(a, name)
    if MapSet.size(a) > @atoms, do: raise(ArgumentError, "too many checkpoint atoms")
    {rest, a, n - 1}
  end
end
