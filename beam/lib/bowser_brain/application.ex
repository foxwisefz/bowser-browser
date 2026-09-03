defmodule BowserBrain.Application do
  @moduledoc """
  The brain's supervision tree (ADR 0002): the Bridge talks to the engine,
  every mod is an isolated child of ModSupervisor, and the Loader hot-reloads
  mod source from disk into the running browser. Any part can crash and
  restart without touching the engine — and vice versa.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: BowserBrain.ModRegistry},
      {Registry, keys: :duplicate, name: BowserBrain.Events},
      # Before every mod: mods read their durable state in init_mod.
      BowserBrain.Store,
      BowserBrain.Profiles,
      # Session and UserContent register for events before Bridge can
      # broadcast a hello.
      BowserBrain.Session,
      BowserBrain.UserContent,
      BowserBrain.Bridge,
      BowserBrain.AgentPort,
      BowserBrain.Surface,
      BowserBrain.ModLog,
      BowserBrain.XFeed,
      BowserBrain.XServer,
      {DynamicSupervisor, name: BowserBrain.ModSupervisor, strategy: :one_for_one},
      BowserBrain.Loader,
      BowserBrain.LibReloader,
      BowserBrain.Settings,
      BowserBrain.SiteMods,
      BowserBrain.ModSmith,
      BowserBrain.Engine
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BowserBrain.Supervisor)
  end
end
