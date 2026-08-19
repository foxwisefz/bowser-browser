defmodule BowserBrain.SurfaceTest do
  # The registry half of Surface (bowser-browser-27l): every show is
  # recorded so panels are enumerable and re-openable. Bridge is down in
  # hermetic tests, so the engine casts drop silently — what we assert is
  # the registry.
  use ExUnit.Case, async: false

  alias BowserBrain.{Surface, View}
  import BowserBrain.View

  test "show records the panel; list returns it" do
    Surface.show(:st_alpha, vstack([text("hi")]), title: "Alpha Panel", kind: :floating)

    assert %{id: "st_alpha", title: "Alpha Panel", kind: "floating", closed: false} =
             Enum.find(Surface.list(), &(&1.id == "st_alpha"))
  end

  test "re-showing updates in place, close marks closed" do
    Surface.show(:st_beta, vstack([text("v1")]), title: "Beta")
    Surface.show(:st_beta, vstack([text("v2")]), title: "Beta v2")
    Surface.close(:st_beta)

    entry = Enum.find(Surface.list(), &(&1.id == "st_beta"))
    assert entry.title == "Beta v2"
    assert entry.closed == true
    assert Enum.count(Surface.list(), &(&1.id == "st_beta")) == 1
  end

  test "reshow replays the stored view and clears closed" do
    Surface.show(:st_gamma, vstack([text("keep me")]), title: "Gamma")
    Surface.close(:st_gamma)
    assert :ok = Surface.reshow("st_gamma")
    assert %{closed: false} = Enum.find(Surface.list(), &(&1.id == "st_gamma"))
  end

  test "reshow of an unknown id errors instead of crashing" do
    assert {:error, :unknown} = Surface.reshow("st_never_shown")
  end

  test "hello marks every panel closed — they die with the engine" do
    Surface.show(:st_roll, vstack([text("x")]), title: "Roll")
    send(Process.whereis(Surface), {:browser_event, %{"event" => "hello"}})
    # Synchronize on the mailbox with a call.
    _ = Surface.list()
    assert %{closed: true} = Enum.find(Surface.list(), &(&1.id == "st_roll"))
  end

  test "toggle suppresses a visible panel and shows drop while suppressed" do
    Surface.show(:st_tog, vstack([text("v1")]), title: "Tog")
    assert {:ok, :hidden} = Surface.toggle("st_tog")
    assert %{closed: true, suppressed: true} = Enum.find(Surface.list(), &(&1.id == "st_tog"))

    # An event-driven mod re-shows while suppressed: recorded, not surfaced.
    Surface.show(:st_tog, vstack([text("v2")]), title: "Tog v2")
    assert %{closed: true, suppressed: true, title: "Tog v2"} =
             Enum.find(Surface.list(), &(&1.id == "st_tog"))

    assert {:ok, :shown} = Surface.toggle("st_tog")
    assert %{closed: false, suppressed: false} = Enum.find(Surface.list(), &(&1.id == "st_tog"))
  end

  test "toggling an unknown id errors" do
    assert {:error, :unknown} = Surface.toggle("st_ghost")
  end

  # Suppress unused alias warning for View (import used above).
  test "view import sanity" do
    assert is_map(vstack([text("x")]))
    _ = View
  end
end
