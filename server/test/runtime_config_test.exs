defmodule BowserServer.RuntimeConfigTest do
  use ExUnit.Case, async: false

  setup do
    names =
      ~w(HOST BOWSER_INTERNAL_HTTP BOWSER_TLS_CERT BOWSER_TLS_KEY BOWSER_TELEMETRY_ENABLED BOWSER_EVENT_RETENTION_DAYS)

    saved = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)
    end)

    :ok
  end

  test "loopback release boots without TLS; container HTTP requires explicit opt-in" do
    assert is_list(Config.Reader.read!("config/runtime.exs", env: :prod))
    System.put_env("HOST", "0.0.0.0")
    assert_raise RuntimeError, fn -> Config.Reader.read!("config/runtime.exs", env: :prod) end
    System.put_env("BOWSER_INTERNAL_HTTP", "1")
    assert is_list(Config.Reader.read!("config/runtime.exs", env: :prod))
  end

  test "telemetry cannot boot without retention and TLS requires both files" do
    System.put_env("BOWSER_TELEMETRY_ENABLED", "1")
    assert_raise RuntimeError, fn -> Config.Reader.read!("config/runtime.exs", env: :prod) end
    System.put_env("BOWSER_EVENT_RETENTION_DAYS", "7")
    assert is_list(Config.Reader.read!("config/runtime.exs", env: :prod))
    System.put_env("BOWSER_TLS_CERT", "certificate.pem")
    assert_raise RuntimeError, fn -> Config.Reader.read!("config/runtime.exs", env: :prod) end
  end
end
