import Config
config :phoenix, :json_library, Jason
# Compile the SQLite NIF for the production image/release platform.
config :exqlite, force_build: config_env() == :prod

config :bowser_server, BowserServerWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "api.bowser.app"],
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
