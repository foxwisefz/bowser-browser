import Config

if config_env() != :test do
  enabled = System.get_env("BOWSER_TELEMETRY_ENABLED") == "1"

  days =
    case System.get_env("BOWSER_EVENT_RETENTION_DAYS") do
      value when value not in [nil, ""] -> String.to_integer(value)
      _ -> nil
    end

  if enabled and (not is_integer(days) or days < 1 or days > 365),
    do: raise("BOWSER_EVENT_RETENTION_DAYS must be 1..365")

  cert = System.get_env("BOWSER_TLS_CERT") |> then(&if(&1 == "", do: nil, else: &1))
  key = System.get_env("BOWSER_TLS_KEY") |> then(&if(&1 == "", do: nil, else: &1))
  if !!cert != !!key, do: raise("Both TLS certificate and key are required")
  host = System.get_env("HOST", "127.0.0.1")
  {:ok, ip} = :inet.parse_address(String.to_charlist(host))
  internal_http = System.get_env("BOWSER_INTERNAL_HTTP") == "1"

  if is_nil(cert) and host not in ["127.0.0.1", "::1"] and not internal_http,
    do: raise("Non-loopback HTTP requires explicit BOWSER_INTERNAL_HTTP=1 behind a private proxy")

  port = String.to_integer(System.get_env("PORT", "8080"))

  transport =
    if cert,
      do: [https: [ip: ip, port: port, certfile: cert, keyfile: key]],
      else: [http: [ip: ip, port: port]]

  config :bowser_server,
         BowserServerWeb.Endpoint,
         transport ++ [server: System.get_env("PHX_SERVER") == "true"]

  config :bowser_server,
    database: System.get_env("BOWSER_DATABASE", Path.expand("data/bowser.sqlite")),
    website:
      System.get_env("BOWSER_WEBSITE") || Application.app_dir(:bowser_server, "priv/static"),
    terms_versions:
      String.split(System.get_env("BOWSER_TERMS_VERSIONS", ""), ",", trim: true)
      |> Enum.map(&String.trim/1),
    telemetry_enabled: enabled,
    event_retention_days: days,
    trusted_proxy: System.get_env("BOWSER_TRUSTED_PROXY"),
    download: System.get_env("BOWSER_DOWNLOAD_PATH")
end
