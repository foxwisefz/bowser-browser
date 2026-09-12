defmodule BowserBrain.Toolbars do
  @moduledoc "Process-owned native edge bars; replayed on reconnect and removed on mod exit."
  use GenServer
  alias BowserBrain.Bridge

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def put(id, view, opts), do: GenServer.call(server(), {:put, id, view, opts})
  def remove(id), do: GenServer.call(server(), {:remove, id})
  def release(owner), do: GenServer.call(server(), {:release, owner})
  def list, do: GenServer.call(server(), :list)

  defp server do
    Process.whereis(__MODULE__) ||
      case Supervisor.start_child(BowserBrain.Supervisor, __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
  end

  def validate(id, view, opts) do
    edge = Keyword.get(opts, :edge, :bottom)
    size = Keyword.get(opts, :size, 28)
    style = Map.new(Keyword.get(opts, :style, %{}))

    valid_style =
      Enum.all?(style, fn
        {k, v}
        when k in [:background, :foreground, :border, :accent, "background", "foreground", "border", "accent"] ->
          BowserBrain.Appearance.valid_color?(v)

        {k, v} when k in [:palette, "palette"] ->
          BowserBrain.Appearance.valid_palette?(v)

        _ ->
          false
      end)

    if is_binary(id) and byte_size(id) in 1..100 and is_map(view) and
         edge in [:top, :bottom, :left, :right] and is_number(size) and size >= 16 and size <= (if edge in [:left, :right], do: 800, else: 200) and
         valid_style do
      {:ok, %{id: id, edge: to_string(edge), size: size, view: view, style: style}}
    else
      {:error, :invalid_toolbar}
    end
  rescue
    _ -> {:error, :invalid_toolbar}
  end

  @impl true
  def init(_) do
    Registry.register(BowserBrain.Events, :browser_event, nil)
    {:ok, []}
  end

  @impl true
  def handle_call({:handoff_restore, checkpoint, owners}, _from, entries) do
    restored = BowserBrain.Handoff.restore_owned_entries(checkpoint, owners)
    Enum.each(entries, fn {_, ref, _} -> Process.demonitor(ref, [:flush]) end)
    Process.put(:published_profiles, Enum.uniq([nil | Enum.map(restored, fn {pid, _, _} -> BowserBrain.ModScope.current(pid) end)]))
    # The native host already displays these entries. Do not replay or clear UI
    # while the candidate is warming; future changes and reconnects publish it.
    {:reply, :ok, restored}
  end

  def handle_call({:put, id, view, opts}, {owner, _}, entries) do
    case validate(id, view, opts) do
      {:ok, bar} ->
        bar = Map.put(bar, :profile, BowserBrain.ModScope.current(owner))
        remaining = drop(entries, owner, id)

        if length(remaining) >= 16 do
          {:reply, {:error, :too_many_toolbars}, entries}
        else
          next = [{owner, Process.monitor(owner), bar} | remaining]
          publish(next)
          {:reply, :ok, next}
        end

      error ->
        {:reply, error, entries}
    end
  end

  def handle_call({:remove, id}, {owner, _}, entries) do
    next = drop(entries, owner, id)
    publish(next)
    {:reply, :ok, next}
  end

  def handle_call({:release, owner}, _, entries) do
    next = drop(entries, owner, :all)
    publish(next)
    {:reply, :ok, next}
  end

  def handle_call(:list, _, entries), do: {:reply, bars(entries), entries}
  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, entries) do
    next = Enum.reject(entries, fn {_, monitor, _} -> monitor == ref end)
    publish(next)
    {:noreply, next}
  end

  def handle_info({:browser_event, %{"event" => "hello"}}, entries) do
    publish(entries)
    {:noreply, entries}
  end

  def handle_info(_, entries), do: {:noreply, entries}

  defp drop(entries, owner, id) do
    Enum.reject(entries, fn {pid, ref, bar} ->
      if pid == owner and (id == :all or bar.id == id) do
        Process.demonitor(ref, [:flush])
        true
      else
        false
      end
    end)
  end

  defp bars(entries),
    do: entries |> Enum.map(&elem(&1, 2)) |> Enum.uniq_by(&{Map.get(&1, :profile), &1.id}) |> Enum.sort_by(& &1.id)

  defp publish(entries) do
    groups = Enum.group_by(bars(entries), &Map.get(&1, :profile))
    profiles = Enum.uniq(Process.get(:published_profiles, [nil]) ++ Map.keys(groups))
    Process.put(:published_profiles, profiles)
    for profile <- profiles do
      Bridge.cast_msg(%{op: "chrome", chrome: "set_toolbars", profile: profile, toolbars: Map.get(groups, profile, [])})
    end
  end
end
