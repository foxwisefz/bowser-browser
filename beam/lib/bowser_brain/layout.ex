defmodule BowserBrain.Layout do
  @moduledoc "Composable native website layouts. Build trees, then apply with Surface.layout/2."

  @doc "A live tab leaf. Options: weight: (positive), min_width:, min_height: (nonnegative points)."
  def webview(id, opts \\ []) when is_integer(id) and id > 0 do
    options(opts) |> Map.merge(%{type: "webview", webview: id})
  end

  @doc "Children side by side. Options: weight:, min_width:, min_height:, resizable: (default true)."
  def row(children, opts \\ []) when is_list(children) and children != [] do
    container("row", children, opts)
  end

  @doc "Children top to bottom. Same options as row/2. Containers may nest in either direction."
  def column(children, opts \\ []) when is_list(children) and children != [] do
    container("column", children, opts)
  end

  defp container(type, children, opts) do
    options(opts) |> Map.put(:resizable, Keyword.get(opts, :resizable, true))
      |> Map.merge(%{type: type, children: children})
  end

  defp options(opts), do: opts |> Keyword.take([:weight, :min_width, :min_height]) |> Map.new()
end
