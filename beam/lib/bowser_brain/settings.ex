defmodule BowserBrain.Settings do
  @moduledoc """
  Flat key/value settings at ~/.bowser/settings.json — hand-editable like
  everything else, or from the omnibar:

      :set dodorouter_endpoint https://router.example.com
      :set dodorouter_api_key sk-...
      :settings                      # show all (secrets masked)

  The file is read fresh on every get, so hand edits apply immediately.
  """
  use GenServer
  require Logger

  import BowserBrain.View
  alias BowserBrain.Surface

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def path, do: Path.join(System.user_home!(), ".bowser/settings.json")

  def all do
    case File.read(path()) do
      {:ok, raw} ->
        case JSON.decode(raw) do
          {:ok, %{} = map} -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  def get(key, default \\ nil), do: Map.get(all(), key, default)

  def put(key, value) do
    map = Map.put(all(), key, value)
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), JSON.encode!(map))
    :ok
  end

  @impl true
  def init(nil) do
    {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:browser_event, %{"event" => "hello"}}, state) do
    BowserBrain.Chrome.register_command("set", "Settings — :set <key> <value>")
    BowserBrain.Chrome.register_command("settings", "Settings — show all")
    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "omnibar_command", "text" => "set " <> rest}}, state) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [key, value] ->
        put(key, value)
        Logger.info("settings: #{key} = #{mask(key, value)}")
        show_all()

      _ ->
        show_all()
    end

    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "omnibar_command", "text" => "settings"}}, state) do
    show_all()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp show_all do
    rows =
      case Enum.sort(all()) do
        [] -> [text("empty — :set <key> <value>", style: :caption)]
        entries -> for {k, v} <- entries, do: text("#{k} = #{mask(k, v)}", style: :caption)
      end

    Surface.show(:settings, vstack(rows), title: "Settings", anchor: :right_of_main, width: 280)
  end

  defp mask(key, value) do
    if String.match?(key, ~r/key|token|secret|password/i) do
      String.slice(to_string(value), 0, 6) <> "…"
    else
      to_string(value)
    end
  end
end
