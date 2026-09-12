defmodule BowserBrain.LegacyMods do
  @moduledoc "Identifies mod sources whose functionality is provided by built-in features."
  @names ["MediaWarmMod", "EdgeDockTabs", "ModSwitchMod", "PanelsMod"]
  def superseded?(path) do
    case File.read(path) do
      {:ok, source} ->
        case Code.string_to_quoted(source) do
          {:ok, ast} ->
            {_, found} = Macro.prewalk(ast, false, fn
              {:defmodule, _, [{:__aliases__, _, parts}, _]} = node, found ->
                {node, found or Enum.join(parts, ".") in @names}
              node, found -> {node, found}
            end)
            found
          _ -> false
        end
      _ -> false
    end
  end
end
