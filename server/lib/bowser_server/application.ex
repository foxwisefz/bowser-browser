defmodule BowserServer.Application do
  use Application

  def start(_, _) do
    Supervisor.start_link(
      [
        {Phoenix.PubSub, name: BowserServer.PubSub},
        {BowserServer.Store, path: Application.fetch_env!(:bowser_server, :database)},
        BowserServer.RateLimit,
        BowserServerWeb.Endpoint
      ], strategy: :one_for_one, name: BowserServer.Supervisor)
  end

  def config_change(changed, removed, _) do
    BowserServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
