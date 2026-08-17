defmodule BowserBrain.Browser do
  @moduledoc """
  What mods call to drive the browser. `webview: 0` means "whichever" —
  the engine resolves it to the first live webview.
  """

  alias BowserBrain.Bridge

  @doc "Navigate a webview to a URL."
  def navigate(url, webview \\ 0) do
    Bridge.cast_msg(%{op: "navigate", webview: webview, url: url})
  end

  @doc """
  Evaluate JavaScript in the page. Returns {:ok, value} | {:error, reason}.
  This is the v0 page-mutation hatch; engine-level DOM hooks are Mod API v1.
  """
  def eval_js(code, webview \\ 0) do
    Bridge.eval_js(webview, code)
  end
end
