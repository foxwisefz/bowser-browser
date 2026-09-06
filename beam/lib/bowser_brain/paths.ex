defmodule BowserBrain.Paths do
  @moduledoc """
  One source of truth for where this Bowser checkout lives. The brain
  compiles on the machine it runs on (single-target project), so the
  default root is derived from this file's location at compile time —
  no hardcoded home directories, runnable from any clone path.

  Overrides, strongest first: `:root` app env (tests), BOWSER_ROOT env
  var (an INSTALLED brain — bin/install sets it to ~/.bowser/app, which
  holds the brain release and helpers), then this checkout.

  BOWSER_ENGINE names the browser binary explicitly; the installed brain
  points it at ~/Applications/Bowser.app so working-copy builds never touch
  the running browser.
  """

  # beam/lib/bowser_brain -> repo root is three levels up.
  @compiled_root Path.expand("../../..", __DIR__)

  @doc """
  The state dir: sockets, session, mods, sites, data, settings, profiles.
  BOWSER_HOME overrides ~/.bowser so a dev brain+browser can run beside the
  installed one (bin/dev uses ~/.bowser-dev). Public for tests via home/1.
  """
  def home, do: home(System.get_env())

  def home(env) when is_map(env) do
    case Map.get(env, "BOWSER_HOME") do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> Path.join(System.user_home!(), ".bowser")
    end
  end

  def root do
    Application.get_env(:bowser_brain, :root) ||
      System.get_env("BOWSER_ROOT") ||
      @compiled_root
  end

  def engine_binary, do: engine_binary(System.get_env())

  @doc "The browser binary for a given environment map. Public for tests."
  def engine_binary(env) when is_map(env) do
    case Map.get(env, "BOWSER_ENGINE") do
      path when is_binary(path) and path != "" -> path
      _ -> Path.join(root(), "shell/.build/debug/Bowser")
    end
  end

  def icon_worker do
    installed = Path.join(root(), "bin/BowserIconWorker")

    if File.regular?(installed),
      do: installed,
      else: Path.join(root(), "shell/.build/debug/BowserIconWorker")
  end

  def engine_wrapper, do: Path.join(root(), "bin/engine-wrapper")
  def brain_lib, do: Path.join(root(), "beam/lib/bowser_brain")
  def mcp_bridge, do: Path.join(root(), "bin/bowser-mcp-bridge")
end
