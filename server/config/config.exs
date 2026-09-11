import Config
config :phoenix, :json_library, Jason

config :bowser_server, BowserServerWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "bowser.app"],
  render_errors: [formats: [json: BowserServerWeb.ErrorJSON], layout: false],
  pubsub_server: BowserServer.PubSub,
  server: false,
  secret_key_base: String.duplicate("development-only-", 8)

config :bowser_server,
  database: ":memory:",
  terms_versions: [],
  telemetry_enabled: false,
  event_retention_days: nil,
  website: Path.expand("../../website", __DIR__)

config :logger, level: :warning
