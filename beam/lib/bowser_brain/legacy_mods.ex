defmodule BowserBrain.LegacyMods do
  @moduledoc "Legacy sources superseded by built-in features; retained on disk for older installations."
  @names ["MediaWarmMod"]
  def superseded?(path) do
    case File.read(path) do
      {:ok, source} ->
        Regex.scan(~r/defmodule\s+([A-Za-z0-9_.]+)/, source)
        |> Enum.any?(fn [_, name] -> name in @names end)
      _ -> false
    end
  end
end
