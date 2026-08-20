defmodule BowserBrain.Paths do
  @moduledoc """
  One source of truth for where this Bowser checkout lives. The brain
  compiles on the machine it runs on (single-target project), so the
  default root is derived from this file's location at compile time —
  no hardcoded home directories, runnable from any clone path.

  Overrides, strongest first: `:root` app env (tests), BOWSER_ROOT env
  var (running a compiled brain against a repo somewhere else).
  """

  # beam/lib/bowser_brain -> repo root is three levels up.
  @compiled_root Path.expand("../../..", __DIR__)

  def root do
    Application.get_env(:bowser_brain, :root) ||
      System.get_env("BOWSER_ROOT") ||
      @compiled_root
  end

  def engine_binary, do: Path.join(root(), "shell/.build/debug/Bowser")
  def engine_wrapper, do: Path.join(root(), "bin/engine-wrapper")
  def brain_lib, do: Path.join(root(), "beam/lib/bowser_brain")
  def mcp_bridge, do: Path.join(root(), "bin/bowser-mcp-bridge")
end
