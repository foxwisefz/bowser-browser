defmodule BowserServerWeb.APIController do
  use Phoenix.Controller, formats: [:json]
  alias BowserServer.{Error, Validation, Store, RateLimit}

  @assets %{
    [] => {"index.html", "text/html"},
    ["index.html"] => {"index.html", "text/html"},
    ["terms.html"] => {"terms.html", "text/html"},
    ["styles.css"] => {"styles.css", "text/css"},
    ["legal.css"] => {"legal.css", "text/css"},
    ["script.js"] => {"script.js", "text/javascript"},
    ["app-icon.webp"] => {"app-icon.webp", "image/webp"}
  }
  # Do not install request/body loggers. Phoenix route logging is disabled to
  # keep query strings and payloads out of operational logs.
  plug(:put_secure_headers)

  def put_secure_headers(conn, _) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", "no-store")
  end

  def health(conn, _), do: json(conn, %{ok: true})

  def method(conn, _),
    do: conn |> put_resp_header("allow", "POST") |> reply(405, "method_not_allowed")

  def register(conn, _) do
    guarded(conn, fn conn ->
      versions = Application.get_env(:bowser_server, :terms_versions, [])
      if versions == [], do: Error.fail(503, "registration_unavailable")
      {body, conn} = body(conn)

      data =
        Validation.registration(
          body,
          List.first(get_req_header(conn, "idempotency-key")),
          versions,
          now()
        )

      {status, response} = Store.run(&Store.register(&1, data, now()))
      conn |> put_status(status) |> json(response)
    end)
  end

  def events(conn, _) do
    guarded(conn, fn conn ->
      unless Application.get_env(:bowser_server, :telemetry_enabled, false),
        do: Error.fail(503, "telemetry_unavailable")

      days = Application.get_env(:bowser_server, :event_retention_days)
      unless is_integer(days) and days in 1..365, do: Error.fail(503, "telemetry_unavailable")
      {body, conn} = body(conn)
      batch = Validation.events(body, now(), days)

      result =
        Store.run(fn db ->
          owner =
            case get_req_header(conn, "authorization") do
              [] -> nil
              ["Bearer " <> token] -> Store.authenticate(db, token)
              _ -> Error.fail(401, "invalid_telemetry_token")
            end

          Store.events(db, batch, owner, now(), days)
        end)

      conn |> put_status(202) |> json(result)
    end)
  end

  defp guarded(conn, fun) do
    remote = conn.remote_ip |> :inet.ntoa() |> to_string()
    proxy = Application.get_env(:bowser_server, :trusted_proxy)

    client =
      if remote == proxy,
        do: List.first(get_req_header(conn, "x-real-ip")) || remote,
        else: remote

    if RateLimit.accept(client) do
      try do
        fun.(conn)
      rescue
        error in Error -> reply(conn, error.status, error.code)
        _ -> reply(conn, 500, "internal_error")
      end
    else
      conn |> put_resp_header("retry-after", "60") |> reply(429, "rate_limited")
    end
  end

  defp body(conn) do
    type = List.first(get_req_header(conn, "content-type")) || ""

    unless Regex.match?(~r/^application\/json(?:\s*;\s*charset=utf-8)?$/i, type),
      do: Error.fail(415, "unsupported_media_type")

    unless get_req_header(conn, "content-encoding") in [[], ["identity"]],
      do: Error.fail(415, "unsupported_encoding")

    case read_body(conn, length: 16_384, read_length: 16_384, read_timeout: 15_000) do
      {:ok, data, conn} ->
        case Jason.decode(data) do
          {:ok, parsed} -> {parsed, conn}
          _ -> Error.fail(400, "invalid_json")
        end

      {:more, _, _} ->
        Error.fail(413, "request_too_large")

      _ ->
        Error.fail(400, "incomplete_request")
    end
  end

  def website(conn, %{"path" => path}) do
    if conn.method in ["GET", "HEAD"] do
      case Map.get(@assets, path) do
        {file, type} ->
          file = Path.join(Application.fetch_env!(:bowser_server, :website), file)

          if File.regular?(file),
            do: send_asset(conn, file, type),
            else: reply(conn, 404, "not_found")

        nil ->
          reply(conn, 404, "not_found")
      end
    else
      reply(conn, 404, "not_found")
    end
  end

  defp send_asset(conn, file, type) do
    conn = put_resp_content_type(conn, type)
    if conn.method == "HEAD", do: send_resp(conn, 200, ""), else: send_file(conn, 200, file)
  end

  defp reply(conn, status, code), do: conn |> put_status(status) |> json(%{error: %{code: code}})
  defp now, do: System.system_time(:millisecond)
end
