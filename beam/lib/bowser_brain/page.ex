defmodule BowserBrain.Page do
  @moduledoc """
  Page-mutation API (Mod API v1). Styles and scripts are ENGINE-injected
  user content: they apply on every load and survive navigation.

  Content is keyed to the calling mod — mods never clobber each other.
  The standard preservation script restores scroll positions across reloads.
  Scripts run in an isolated world by default. Explicit `world: :page`
  grants access to website JavaScript globals.
  """

  alias BowserBrain.{Bridge, UserContent}

  @doc "Replace THIS MOD's stylesheets. `[]` clears them."
  def set_styles(styles, opts \\ []) when is_list(styles) do
    UserContent.put_styles(owner(), styles, opts)
  end

  @doc """
  Replace THIS MOD's user scripts. `[]` clears them. Defaults to an isolated
  JavaScript world; pass `world: :page` to access website globals. A declared
  mod host is enforced by the engine on injected scripts.
  """
  def set_scripts(scripts, opts \\ []) when is_list(scripts) do
    UserContent.put_scripts(owner(), scripts, opts)
  end

  @doc """
  One-off JS in the current page. Returns {:ok, value} | {:error, reason}.
  Options: `webview: 0`, `timeout: 5000`, `world: :isolated | :page`.
  """
  def eval(code, opts \\ []) do
    world = BowserBrain.ScriptPolicy.world!(Keyword.get(opts, :world, :isolated))
    Bridge.eval_js(Keyword.get(opts, :webview, 0), code, Keyword.get(opts, :timeout, 5_000), world)
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
