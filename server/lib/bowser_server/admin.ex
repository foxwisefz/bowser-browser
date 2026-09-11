defmodule BowserServer.Admin do
  alias BowserServer.Store

  def run(operation, argument \\ nil) do
    Application.ensure_all_started(:bowser_server)

    Store.run(fn db ->
      case operation do
        "backup" when is_binary(argument) ->
          Store.backup(db, argument)

        "prune-events" ->
          Store.prune(db, System.system_time(:millisecond))

        "withdraw-training" when is_binary(argument) ->
          Store.withdraw(db, argument)

        "delete-registration" when is_binary(argument) ->
          Store.delete(db, argument)

        _ ->
          raise "Expected backup PATH, prune-events, withdraw-training ID or delete-registration ID"
      end
    end)

    :ok
  end
end
