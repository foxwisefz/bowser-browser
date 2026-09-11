defmodule BowserBrain.UserContentTest do
  use ExUnit.Case, async: true
  alias BowserBrain.UserContent

  test "replacing and clearing one owner retains other owners and content kinds" do
    state = %{scripts: %{}, styles: %{}}

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :scripts, {:a, "work"}, ["old"], false}, nil, state)

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :scripts, {:b, "work"}, ["keep"], false}, nil, state)

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :styles, {:a, "work"}, ["css"], false}, nil, state)

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :scripts, {:a, "work"}, ["replacement"], false}, nil, state)

    assert state.scripts == %{{:a, "work"} => ["replacement"], {:b, "work"} => ["keep"]}

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :scripts, {:a, "work"}, [], false}, nil, state)

    assert state.scripts == %{{:b, "work"} => ["keep"]}
    assert state.styles == %{{:a, "work"} => ["css"]}
  end
end
