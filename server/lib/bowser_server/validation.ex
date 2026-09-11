defmodule BowserServer.Validation do
  alias BowserServer.Error
  def check(value, code \\ "invalid_request"), do: if(value, do: :ok, else: Error.fail(400, code))

  def object(value, keys, required \\ nil) do
    check(is_map(value))

    check(
      Enum.all?(Map.keys(value), &(&1 in keys)) and
        Enum.all?(required || keys, &Map.has_key?(value, &1))
    )
  end

  def text(value, max) do
    check(
      is_binary(value) and String.valid?(value) and String.length(value) in 1..max and
        not Regex.match?(~r/[\x00-\x1f\x7f]/, value)
    )

    value
  end

  def uuid(value) do
    check(
      is_binary(value) and
        Regex.match?(
          ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
          value
        )
    )

    String.downcase(value)
  end

  def timestamp(value, now) do
    check(
      is_binary(value) and
        Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/, value)
    )

    case DateTime.from_iso8601(value) do
      {:ok, date, 0} ->
        check(DateTime.to_unix(date, :millisecond) <= now + 300_000)

        date
        |> DateTime.to_unix(:millisecond)
        |> DateTime.from_unix!(:millisecond)
        |> DateTime.to_iso8601()

      _ ->
        Error.fail(400, "invalid_request")
    end
  end

  def registration(body, key, versions, now) do
    fields = ~w(requestID email termsVersion acceptedAt trainingConsent)
    object(body, fields ++ ["device"], fields)
    id = uuid(body["requestID"])
    check(uuid(key) == id, "idempotency_key_mismatch")
    email = body["email"] |> text(254) |> String.trim()
    check(Regex.match?(~r/^[^@<>\s]+@[^@<>.\s]+(?:\.[^@<>.\s]+)+$/, email))
    version = text(body["termsVersion"], 80)
    unless version in versions, do: Error.fail(422, "unsupported_terms_version")
    check(is_boolean(body["trainingConsent"]))

    result = %{
      body
      | "requestID" => id,
        "email" => email,
        "acceptedAt" => timestamp(body["acceptedAt"], now)
    }

    if Map.has_key?(body, "device") do
      object(body["device"], ~w(model architecture macOSVersion appVersion appBuild))
      Enum.each(body["device"], fn {_, v} -> text(v, 100) end)
      check(body["device"]["architecture"] == "arm64")
    end

    result
  end

  def events(body, now, days) do
    object(body, ["events"])
    batch = body["events"]
    check(is_list(batch) and length(batch) in 1..25)

    events =
      Enum.map(batch, fn event ->
        object(event, ~w(eventID name occurredAt properties))
        id = uuid(event["eventID"])
        date = timestamp(event["occurredAt"], now)

        check(
          DateTime.to_unix(DateTime.from_iso8601(date) |> elem(1), :millisecond) >=
            now - days * 86_400_000,
          "event_expired"
        )

        common = ~w(appVersion appBuild)

        allowed =
          case event["name"] do
            "registration_completed" -> common
            "modsmith_outcome" -> common ++ ~w(operation outcome durationMs failureCategory)
            "crash" -> common ++ ["category"]
            _ -> Error.fail(400, "unknown_event")
          end

        props = event["properties"]
        object(props, allowed, common)

        for field <- common,
            do: check(Regex.match?(~r/^[A-Za-z0-9._+-]+$/, text(props[field], 64)))

        if event["name"] == "modsmith_outcome" do
          check(props["operation"] in ~w(create refine undo))
          check(props["outcome"] in ~w(succeeded failed cancelled))

          if Map.has_key?(props, "durationMs"),
            do: check(is_integer(props["durationMs"]) and props["durationMs"] in 0..3_600_000)

          if Map.has_key?(props, "failureCategory"),
            do:
              check(
                props["outcome"] == "failed" and
                  props["failureCategory"] in ~w(provider timeout validation runtime unknown)
              )
        end

        if event["name"] == "crash",
          do: check(props["category"] in ~w(native backend mod unknown))

        %{event | "eventID" => id, "occurredAt" => date}
      end)

    check(length(Enum.uniq_by(events, & &1["eventID"])) == length(events))
    events
  end
end
