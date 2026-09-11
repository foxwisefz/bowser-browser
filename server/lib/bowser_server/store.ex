defmodule BowserServer.Store do
  use GenServer
  alias Exqlite.Sqlite3, as: SQL
  alias BowserServer.Error

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def run(fun, server \\ __MODULE__) do
    case GenServer.call(server, {:run, fun}, 15_000) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  def query(db, sql, args \\ []) do
    {:ok, stmt} = SQL.prepare(db, sql)

    try do
      :ok = SQL.bind(stmt, args)
      {:ok, rows} = SQL.fetch_all(db, stmt)
      rows
    after
      SQL.release(db, stmt)
    end
  end

  def transaction(db, fun) do
    :ok = SQL.execute(db, "BEGIN IMMEDIATE")

    try do
      result = fun.()
      :ok = SQL.execute(db, "COMMIT")
      result
    rescue
      error ->
        SQL.execute(db, "ROLLBACK")
        reraise error, __STACKTRACE__
    end
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)

    if path != ":memory:" do
      File.mkdir_p!(Path.dirname(path))
      unless File.exists?(path), do: File.write!(path, "", [:exclusive])
      File.chmod!(path, 0o600)
    end

    {:ok, db} = SQL.open(path)

    :ok =
      SQL.execute(db, """
      PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=2000;
      CREATE TABLE IF NOT EXISTS registrations (
        request_id TEXT PRIMARY KEY, registration_id TEXT NOT NULL UNIQUE,
        payload_hash TEXT NOT NULL, payload TEXT NOT NULL, received_at TEXT NOT NULL,
        training_consent INTEGER NOT NULL CHECK(training_consent IN (0,1)), consent_updated_at TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS events (
        event_id TEXT PRIMARY KEY, registration_id TEXT REFERENCES registrations(registration_id) ON DELETE CASCADE,
        name TEXT NOT NULL, payload_hash TEXT NOT NULL, payload TEXT NOT NULL, received_at TEXT NOT NULL, expires_at INTEGER NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS events_expiry ON events(expires_at);
      """)

    query(db, "INSERT OR IGNORE INTO metadata VALUES(?,?)", [
      "telemetry_secret",
      Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    ])

    prune(db, System.system_time(:millisecond))
    Process.send_after(self(), :prune, 60_000)
    {:ok, db}
  end

  @impl true
  def handle_call({:run, fun}, _, db) do
    result =
      try do
        {:ok, fun.(db)}
      rescue
        error -> {:error, error}
      end

    {:reply, result, db}
  end

  @impl true
  def handle_info(:prune, db) do
    try do
      prune(db, System.system_time(:millisecond))
    rescue
      _ -> :ok
    end

    Process.send_after(self(), :prune, 60_000)
    {:noreply, db}
  end

  @impl true
  def terminate(_, db), do: SQL.close(db)
  def now_iso(now), do: now |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  def hash(data), do: :crypto.hash(:sha256, Jason.encode!(data)) |> Base.encode16(case: :lower)

  def register(db, payload, now) do
    transaction(db, fn ->
      case query(db, "SELECT registration_id,payload FROM registrations WHERE request_id=?", [
             payload["requestID"]
           ]) do
        [[id, saved]] ->
          unless Jason.decode!(saved) == payload, do: Error.fail(409, "idempotency_conflict")
          {200, %{registrationID: id, telemetryToken: token(db, id)}}

        [] ->
          id = uuid()

          query(db, "INSERT INTO registrations VALUES(?,?,?,?,?,?,?)", [
            payload["requestID"],
            id,
            hash(payload),
            Jason.encode!(payload),
            now_iso(now),
            if(payload["trainingConsent"], do: 1, else: 0),
            now_iso(now)
          ])

          {201, %{registrationID: id, telemetryToken: token(db, id)}}
      end
    end)
  end

  def uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    Enum.map_join(
      [{a, 8}, {b, 4}, {Bitwise.bor(c, 0x4000), 4}, {Bitwise.bor(d, 0x8000), 4}, {e, 12}],
      "-",
      fn {v, n} -> Integer.to_string(v, 16) |> String.downcase() |> String.pad_leading(n, "0") end
    )
  end

  def token(db, id) do
    [[secret]] = query(db, "SELECT value FROM metadata WHERE key='telemetry_secret'")
    id <> "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, id), padding: false)
  end

  def authenticate(db, supplied) do
    with [_, id, _] <- Regex.run(~r/^([a-f0-9-]{36})\.([A-Za-z0-9_-]{43})$/, supplied),
         true <- Plug.Crypto.secure_compare(token(db, id), supplied),
         [[^id]] <-
           query(db, "SELECT registration_id FROM registrations WHERE registration_id=?", [id]) do
      id
    else
      _ -> Error.fail(401, "invalid_telemetry_token")
    end
  end

  def events(db, batch, owner, now, days) do
    transaction(db, fn ->
      prune(db, now)

      accepted =
        Enum.count(batch, fn event ->
          case query(db, "SELECT registration_id,payload FROM events WHERE event_id=?", [
                 event["eventID"]
               ]) do
            [[old_owner, saved]] ->
              unless old_owner == owner and Jason.decode!(saved) == event,
                do: Error.fail(409, "idempotency_conflict")

              false

            [] ->
              query(db, "INSERT INTO events VALUES(?,?,?,?,?,?,?)", [
                event["eventID"],
                owner,
                event["name"],
                hash(event),
                Jason.encode!(event),
                now_iso(now),
                now + days * 86_400_000
              ])

              true
          end
        end)

      %{accepted: accepted, duplicates: length(batch) - accepted}
    end)
  end

  def prune(db, now), do: query(db, "DELETE FROM events WHERE expires_at<=?", [now])

  def withdraw(db, id),
    do:
      query(
        db,
        "UPDATE registrations SET training_consent=0,consent_updated_at=? WHERE registration_id=?",
        [now_iso(System.system_time(:millisecond)), id]
      )

  def delete(db, id), do: query(db, "DELETE FROM registrations WHERE registration_id=?", [id])

  def backup(db, path) do
    if File.exists?(path), do: raise("Backup destination must not exist")
    query(db, "VACUUM INTO ?", [Path.expand(path)])
    File.chmod!(path, 0o600)
  end
end
