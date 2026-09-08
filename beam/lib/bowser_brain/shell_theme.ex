defmodule BowserBrain.ShellTheme do
  @moduledoc """
  Process-owned shell themes. The most recently changed theme wins; removing
  its owner restores the previous theme. Engine reconnects replay the winner.
  """
  use GenServer
  alias BowserBrain.Bridge

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def set(theme), do: GenServer.call(server(), {:set, theme})
  def reset, do: GenServer.call(server(), :reset)
  def current, do: GenServer.call(server(), :current)
  def release(owner), do: GenServer.call(server(), {:release, owner})

  # A dev brain can hot-load this API before its supervision tree has been
  # restarted. Add the new child to that same supervisor on first use.
  defp server do
    case Process.whereis(__MODULE__) do
      nil ->
        case Supervisor.start_child(BowserBrain.Supervisor, __MODULE__) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  @colors ~w(background foreground button_background button_foreground accent border window_border)
  @doc "Validate the complete theme before replacing a mod's previous theme."
  def validate(theme) when is_map(theme) do
    if Enum.all?(Map.keys(theme), &(is_atom(&1) or is_binary(&1))) do
      validate_keys(Map.new(theme, fn {k, v} -> {to_string(k), v} end))
    else
      {:error, :invalid_theme}
    end
  end

  def validate(_), do: {:error, :invalid_theme}

  defp validate_keys(theme) do
    if Enum.all?(theme, fn
         {key, value} when key in @colors ->
           is_binary(value) and Regex.match?(~r/^#[0-9a-fA-F]{6}$/, value)

         {"button_style", value} ->
           value in ["flat", "beveled"]

         {"window_border_style", value} -> value in ["flat", "beveled"]
         {"window_border_width", value} -> is_number(value) and value >= 0 and value <= 12

         {"show_navigation", value} ->
           is_boolean(value)

         {"title_size", value} ->
           is_number(value) and value >= 9 and value <= 16

         {"corner_radius", value} ->
           is_number(value) and value >= 0 and value <= 12

         _ ->
           false
       end), do: {:ok, theme}, else: {:error, :invalid_theme}
  end

  @impl true
  def init(nil) do
    Registry.register(BowserBrain.Events, :browser_event, nil)
    {:ok, []}
  end

  @impl true
  def handle_call({:set, theme}, {owner, _}, entries) do
    case validate(theme) do
      {:ok, theme} ->
        entries = remove(entries, owner)
        entries = [{owner, Process.monitor(owner), theme} | entries]
        publish(entries)
        {:reply, :ok, entries}

      error ->
        {:reply, error, entries}
    end
  end

  def handle_call(:reset, {owner, _}, entries) do
    entries = remove(entries, owner)
    publish(entries)
    {:reply, :ok, entries}
  end

  def handle_call({:release, owner}, _from, entries) do
    entries = remove(entries, owner)
    publish(entries)
    {:reply, :ok, entries}
  end

  def handle_call(:current, _from, entries), do: {:reply, theme(entries), entries}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, entries) do
    entries = Enum.reject(entries, fn {_, monitor, _} -> monitor == ref end)
    publish(entries)
    {:noreply, entries}
  end

  def handle_info({:browser_event, %{"event" => "hello"}}, entries) do
    publish(entries)
    {:noreply, entries}
  end

  def handle_info(_, entries), do: {:noreply, entries}

  defp remove(entries, owner) do
    Enum.reject(entries, fn {pid, monitor, _} ->
      if pid == owner do
        Process.demonitor(monitor, [:flush])
        true
      else
        false
      end
    end)
  end

  defp theme([{_, _, theme} | _]), do: theme
  defp theme([]), do: %{}

  defp publish(entries),
    do: Bridge.cast_msg(%{op: "chrome", chrome: "set_theme", theme: theme(entries)})
end
