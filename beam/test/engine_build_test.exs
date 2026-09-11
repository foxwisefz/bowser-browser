defmodule BowserBrain.EngineBuildTest do
  use ExUnit.Case, async: true
  alias BowserBrain.{EngineBuild, Bridge}

  defp macho(id) do
    <<0xFEEDFACF::little-32, 0::96, 1::little-32, 24::little-32, 0::64,
      0x1B::little-32, 24::little-32, id::binary-size(16)>>
  end

  test "mapped build identity detects a replaced executable and tolerates legacy hello" do
    path = Path.join(System.tmp_dir!(), "engine-build-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    old = :binary.copy(<<1>>, 16)
    File.write!(path, macho(old))
    hello = %{"engine_build_id" => Base.encode16(old, case: :lower), "engine_binary" => path}
    assert EngineBuild.status(hello).stale == false
    File.write!(path, macho(:binary.copy(<<2>>, 16)))
    assert EngineBuild.status(hello).stale == true
    File.write!(path, <<0>>)
    assert EngineBuild.status(hello).stale == nil
    assert EngineBuild.status(%{}).stale == nil
    File.write!(path, <<0xFEEDFACF::little-32, 0::96, 1::little-32, 8::little-32, 0::64, 1::little-32, 0::little-32>>)
    assert EngineBuild.disk_id(path) == nil
  end

  test "URL duplicates are scoped to a tab and reset on navigation and close" do
    event = %{"event" => "url_changed", "webview" => 1, "url" => "https://example.test"}
    assert {true, first} = Bridge.accept_event(event, %{})
    assert {false, ^first} = Bridge.accept_event(event, first)
    assert {true, _} = Bridge.accept_event(Map.put(event, "webview", 2), first)
    assert {true, changed} = Bridge.accept_event(Map.put(event, "url", "https://other.test"), first)
    assert {true, _} = Bridge.accept_event(event, changed)
    for reset <- [%{"event" => "webview_closed", "webview" => 1},
                  %{"event" => "load_status", "status" => 0, "webview" => 1}] do
      assert {true, reset_state} = Bridge.accept_event(reset, first)
      assert {true, _} = Bridge.accept_event(event, reset_state)
    end
  end
end
