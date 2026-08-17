defmodule BowserBrain.Page do
  @moduledoc """
  Page-mutation API (Mod API v1). Styles and scripts set here are injected
  by the ENGINE (Servo's user-content manager), not eval'd — they apply on
  every load of every page in the webview, and survive navigation. Setting
  new content reloads the page by default so it takes effect immediately.
  """

  alias BowserBrain.Bridge

  @doc """
  Replace the mod stylesheets for a webview. `[]` clears them.

      Page.set_styles(["article { max-width: 60ch; margin: auto; }"])
  """
  def set_styles(styles, opts \\ []) when is_list(styles) do
    Bridge.cast_msg(%{
      op: "set_user_content",
      webview: Keyword.get(opts, :webview, 0),
      styles: styles,
      reload: Keyword.get(opts, :reload, true)
    })
  end

  @doc "Replace the mod user scripts (run in every page). `[]` clears."
  def set_scripts(scripts, opts \\ []) when is_list(scripts) do
    Bridge.cast_msg(%{
      op: "set_user_content",
      webview: Keyword.get(opts, :webview, 0),
      scripts: scripts,
      reload: Keyword.get(opts, :reload, true)
    })
  end

  @doc "One-off JS in the current page. Returns {:ok, value} | {:error, reason}."
  def eval(code, opts \\ []) do
    Bridge.eval_js(Keyword.get(opts, :webview, 0), code)
  end
end
