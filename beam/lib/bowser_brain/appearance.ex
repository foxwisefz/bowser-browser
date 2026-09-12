defmodule BowserBrain.Appearance do
  @moduledoc "Validation for native semantic colors, scoped palette tokens and appearance variants."
  @variants ~w(light dark high_contrast_light high_contrast_dark)

  def valid_color?(value, depth \\ 0)
  def valid_color?(_, depth) when depth >= 8, do: false
  def valid_color?(value, depth) when is_atom(value) and value not in [nil, true, false],
    do: valid_color?(Atom.to_string(value), depth)
  def valid_color?(value, _) when is_binary(value),
    do: Regex.match?(~r/^(#[0-9a-fA-F]{6}|[a-z][a-z0-9_]{0,63})$/, value)
  def valid_color?(value, depth) when is_map(value) do
    with {:ok, map} <- string_keys(value) do
      Map.has_key?(map, "light") and Map.has_key?(map, "dark") and
        Enum.all?(map, fn {k, v} -> k in @variants and valid_color?(v, depth + 1) end)
    else
      _ -> false
    end
  end
  def valid_color?(_, _), do: false

  def valid_palette?(palette) when is_map(palette) and map_size(palette) <= 64 do
    with {:ok, palette} <- string_keys(palette) do
      Enum.all?(palette, fn {key, value} ->
        Regex.match?(~r/^[a-z][a-z0-9_]{0,63}$/, key) and valid_color?(value)
      end)
    else
      _ -> false
    end
  end
  def valid_palette?(_), do: false

  defp string_keys(map) do
    if Enum.all?(Map.keys(map), &(is_binary(&1) or (is_atom(&1) and &1 not in [nil, true, false]))) do
      result = Map.new(map, fn {k, v} -> {to_string(k), v} end)
      if map_size(result) == map_size(map), do: {:ok, result}, else: :error
    else
      :error
    end
  end
end
