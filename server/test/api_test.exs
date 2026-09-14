defmodule BowserServer.APITest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  alias BowserServer.{Store, RateLimit}
  @endpoint BowserServerWeb.Endpoint
  setup do
    RateLimit.reset()

    Store.run(fn db ->
      Store.query(db, "DELETE FROM events")
      Store.query(db, "DELETE FROM registrations")
    end)

    Application.put_env(:bowser_server, :terms_versions, ["fixture"])
    Application.put_env(:bowser_server, :telemetry_enabled, true)
    Application.put_env(:bowser_server, :event_retention_days, 7)
    :ok
  end

  def payload do
    %{
      "requestID" => Store.uuid(),
      "email" => "person@example.com",
      "termsVersion" => "fixture",
      "acceptedAt" => Store.now_iso(System.system_time(:millisecond)),
      "trainingConsent" => false,
      "device" => %{
        "model" => "Mac14,5",
        "architecture" => "arm64",
        "macOSVersion" => "15.0",
        "appVersion" => "1.0",
        "appBuild" => "42"
      }
    }
  end

  def event(name \\ "crash", extra \\ %{"category" => "native"}) do
    %{
      "eventID" => Store.uuid(),
      "name" => name,
      "occurredAt" => Store.now_iso(System.system_time(:millisecond)),
      "properties" => Map.merge(%{"appVersion" => "1.0", "appBuild" => "42"}, extra)
    }
  end

  def request(path, body, headers \\ []) do
    conn = build_conn() |> put_req_header("content-type", "application/json")
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    post(conn, path, Jason.encode!(body))
  end

  def register(data),
    do: request("/v1/registrations", data, [{"idempotency-key", data["requestID"]}])

  test "concurrent registration retries persist one ID and token with server time" do
    data = payload()

    responses =
      1..8 |> Task.async_stream(fn _ -> register(data) end) |> Enum.map(fn {:ok, c} -> c end)

    assert Enum.count(responses, &(&1.status == 201)) == 1
    values = Enum.map(responses, &Jason.decode!(&1.resp_body))
    assert length(Enum.uniq(values)) == 1

    assert [[received, 0]] =
             Store.run(&Store.query(&1, "SELECT received_at,training_consent FROM registrations"))

    assert {:ok, _, _} = DateTime.from_iso8601(received)
    assert register(%{data | "trainingConsent" => true}).status == 409
  end

  test "strict native payload rejects extra/private fields, wrong versions, dates and keys" do
    for changes <- [
          %{"serialNumber" => "private"},
          %{"privacyVersion" => "old"},
          %{"trainingConsent" => "yes"},
          %{"device" => Map.put(payload()["device"], "hardwareUUID", "private")},
          %{"email" => "a@@b.com"},
          %{"acceptedAt" => "2026-02-30T09:00:00Z"}
        ] do
      conn = register(Map.merge(payload(), changes))
      assert conn.status == 400
      refute conn.resp_body =~ "private"
    end

    assert register(%{payload() | "termsVersion" => "old"}).status == 422

    assert request("/v1/registrations", payload(), [{"idempotency-key", Store.uuid()}]).status ==
             400

    assert [[0]] = Store.run(&Store.query(&1, "SELECT count(*) FROM registrations"))
  end

  test "optional device and unverified email do not link registrations" do
    data = payload() |> Map.delete("device")
    a = register(data) |> json_response(201)
    b = register(%{data | "requestID" => Store.uuid()}) |> json_response(201)
    refute a["registrationID"] == b["registrationID"]
  end

  test "rate limiting ignores untrusted forwarded addresses" do
    for _ <- 1..20, do: assert(register(payload()).status == 201)
    conn = request("/v1/registrations", payload(), [{"x-real-ip", "1.2.3.4"}])
    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") == ["60"]
  end

  test "website allowlist, inactive APIs, body limits and methods" do
    assert get(build_conn(), "/").status == 200
    assert get(build_conn(), "/terms.html").status == 200

    for path <- ~w(/privacy.html /src/main.js /data.sqlite /%2e%2e/server/mix.exs),
        do: assert(get(build_conn(), path).status == 404)

    assert get(build_conn(), "/v1/registrations").status == 405
    assert get(build_conn(), "/Bowser.dmg").status == 404
    assert register(%{payload() | "email" => String.duplicate("x", 17000)}).status == 413

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/registrations", "{")

    assert conn.status == 400
    Application.put_env(:bowser_server, :terms_versions, [])
    assert register(payload()).status == 503
    Application.put_env(:bowser_server, :telemetry_enabled, false)
    assert request("/v1/events", %{"events" => [event()]}).status == 503
  end

  test "three approved events deduplicate and reject free text or extra fields" do
    events = [
      event(),
      event("registration_completed", %{}),
      event("modsmith_outcome", %{
        "operation" => "create",
        "outcome" => "failed",
        "failureCategory" => "provider",
        "durationMs" => 123
      })
    ]

    assert request("/v1/events", %{"events" => events}) |> json_response(202) == %{
             "accepted" => 3,
             "duplicates" => 0
           }

    assert request("/v1/events", %{"events" => events}) |> json_response(202) == %{
             "accepted" => 0,
             "duplicates" => 3
           }

    for field <- ~w(url prompt code stack message email) do
      assert request("/v1/events", %{
               "events" => [event("crash", %{"category" => "native", field => "private"})]
             }).status == 400
    end

    assert request("/v1/events", %{"events" => [event("page_view", %{})]}).status == 400

    assert request("/v1/events", %{"events" => [event("crash", %{"category" => "free text"})]}).status ==
             400

    assert request("/v1/events", %{"events" => Enum.map(1..26, fn _ -> event() end)}).status ==
             400
  end

  test "event conflicts roll back the entire batch" do
    original = event()
    request("/v1/events", %{"events" => [original]})
    changed = put_in(original, ["properties", "category"], "backend")
    assert request("/v1/events", %{"events" => [event(), changed]}).status == 409
    assert [[1]] = Store.run(&Store.query(&1, "SELECT count(*) FROM events"))
  end

  test "token attribution, withdrawal-safe retries and deletion cascade" do
    data = %{payload() | "trainingConsent" => true}
    receipt = register(data) |> json_response(201)
    id = receipt["registrationID"]
    token = receipt["telemetryToken"]

    assert request("/v1/events", %{"events" => [event()]}, [{"authorization", "Bearer " <> token}]).status ==
             202

    assert [[^id]] = Store.run(&Store.query(&1, "SELECT registration_id FROM events"))

    assert request("/v1/events", %{"events" => [event()]}, [{"authorization", "Bearer bad"}]).status ==
             401

    Store.run(&Store.withdraw(&1, id))
    assert register(data).status == 200
    assert [[0]] = Store.run(&Store.query(&1, "SELECT training_consent FROM registrations"))
    Store.run(&Store.delete(&1, id))
    assert [[0]] = Store.run(&Store.query(&1, "SELECT count(*) FROM events"))

    assert request("/v1/events", %{"events" => [event()]}, [{"authorization", "Bearer " <> token}]).status ==
             401
  end

  test "event retention removes expired data" do
    request("/v1/events", %{"events" => [event()]})
    Store.run(&Store.prune(&1, System.system_time(:millisecond) + 7 * 86_400_000))
    assert [[0]] = Store.run(&Store.query(&1, "SELECT count(*) FROM events"))

    old = %{
      event()
      | "occurredAt" => Store.now_iso(System.system_time(:millisecond) - 8 * 86_400_000)
    }

    assert request("/v1/events", %{"events" => [old]}).status == 400
  end
end
