defmodule BowserMobileExperiment.Application do
  use Application
  def start(_, _) do
    Supervisor.start_link([BowserBrain.XFeed, BowserBrain.XServer],
      strategy: :one_for_one, name: BowserMobileExperiment.Supervisor)
  end
end
