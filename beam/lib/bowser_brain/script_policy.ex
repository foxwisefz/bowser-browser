defmodule BowserBrain.ScriptPolicy do
  @moduledoc false

  def world!(value) when value in [:isolated, "isolated"], do: "isolated"
  def world!(value) when value in [:page, "page"], do: "page"
  def world!(_), do: raise(ArgumentError, "script world must be isolated or page")

  # Capability markers belong at the start of a payload, after its optional
  # profile tag. A marker in a quoted string or later comment has no effect.
  def source_world(source) when is_binary(source) do
    lines = source |> String.trim_leading() |> String.split("\n")
    lines = case lines do
      ["// bowser-profile: " <> _ | rest] -> Enum.drop_while(rest, &(String.trim(&1) == ""))
      _ -> lines
    end
    case lines do
      ["// bowser-world: " <> world | _] -> world!(String.trim(world))
      _ -> "isolated"
    end
  end

  def normalize(script, opts \\ [])
  def normalize(source, opts) when is_binary(source) do
    normalize(%{source: source, world: Keyword.get(opts, :world, :isolated)}, opts)
  end
  def normalize(script, opts) when is_map(script) do
    source = Map.get(script, :source, Map.get(script, "source"))
    unless is_binary(source), do: raise(ArgumentError, "script source must be a string")
    world = Map.get(script, :world, Map.get(script, "world", Keyword.get(opts, :world, :isolated)))
    result = %{source: source, world: world!(world)}
    Enum.reduce([:host, :origin], result, fn key, acc ->
      value = Keyword.get(opts, key) || Map.get(script, key, Map.get(script, Atom.to_string(key)))
      case value do
        nil -> acc
        value when is_binary(value) and byte_size(value) > 0 -> Map.put(acc, key, value)
        _ -> raise ArgumentError, "script #{key} must be a nonempty string"
      end
    end)
  end
  def normalize(_, _), do: raise(ArgumentError, "script must be a string or descriptor")

  def owner_host(owner) when is_atom(owner) do
    if function_exported?(owner, :__bowser_host__, 0), do: owner.__bowser_host__(), else: nil
  end
  def owner_host(_), do: nil
end
