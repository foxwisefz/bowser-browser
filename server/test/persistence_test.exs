defmodule BowserServer.PersistenceTest do
  use ExUnit.Case, async: false
  alias BowserServer.Store

  test "disk restart and backup preserve registration, token and withdrawn consent" do
    dir = Path.join(System.tmp_dir!(), "bowser-store-#{Store.uuid()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "live.sqlite")
    backup = Path.join(dir, "backup.sqlite")
    {:ok, pid} = Store.start_link(path: path, name: nil)
    now = System.system_time(:millisecond)

    payload = %{
      "requestID" => Store.uuid(),
      "email" => "fixture@example.com",
      "termsVersion" => "fixture",
      "acceptedAt" => Store.now_iso(now),
      "trainingConsent" => true
    }

    {201, receipt} = Store.run(&Store.register(&1, payload, now), pid)

    Store.run(
      fn db ->
        Store.withdraw(db, receipt.registrationID)
        Store.backup(db, backup)
      end,
      pid
    )

    assert_raise RuntimeError, fn -> Store.run(&Store.backup(&1, backup), pid) end
    GenServer.stop(pid)

    for file <- [path, backup] do
      {:ok, reopened} = Store.start_link(path: file, name: nil)
      assert {200, ^receipt} = Store.run(&Store.register(&1, payload, now), reopened)

      assert receipt.registrationID ==
               Store.run(&Store.authenticate(&1, receipt.telemetryToken), reopened)

      assert [[0]] ==
               Store.run(&Store.query(&1, "SELECT training_consent FROM registrations"), reopened)

      GenServer.stop(reopened)
    end
  end
end
