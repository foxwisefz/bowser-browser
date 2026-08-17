defmodule BowserBrain.Page do
  @moduledoc """
  Page-mutation API (Mod API v1). Styles and scripts are ENGINE-injected
  (Servo user content): they apply on every load and survive navigation.

  Content is keyed to the calling mod — mods never clobber each other.
  Scroll and non-sensitive form values are preserved across reloads for
  free by the standard preservation script (see BowserBrain.UserContent);
  mods do not need to hand-roll that.
  """

  alias BowserBrain.{Bridge, UserContent}

  @doc "Replace THIS MOD's stylesheets. `[]` clears them."
  def set_styles(styles, opts \\ []) when is_list(styles) do
    UserContent.put_styles(owner(), styles, opts)
  end

  @doc "Replace THIS MOD's user scripts. `[]` clears them."
  def set_scripts(scripts, opts \\ []) when is_list(scripts) do
    UserContent.put_scripts(owner(), scripts, opts)
  end

  @doc "One-off JS in the current page. Returns {:ok, value} | {:error, reason}."
  def eval(code, opts \\ []) do
    Bridge.eval_js(Keyword.get(opts, :webview, 0), code)
  end

  # A mod's process is registered under its module name; anything else
  # (iex, tests) shares the :global bucket.
  defp owner do
    case Registry.keys(BowserBrain.ModRegistry, self()) do
      [module | _] -> module
      [] -> :global
    end
  end
end
