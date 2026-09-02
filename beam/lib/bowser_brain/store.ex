defmodule BowserBrain.Store do
  @moduledoc """
  Durable per-mod key/value (bowser-browser-39o): the thing a mod reaches
  for when it must remember something across days and brain restarts —
  who it followed and when, what the owner whitelisted, a counter.

  One JSON file per mod under ~/.bowser/data/<Mod>.json, written atomically
  (tmp + rename), cached in this server. Keys are strings; values must be
  JSON-shaped (maps, lists, strings, numbers, booleans, nil) and come back
  the way JSON gives them: string keys, no atoms.

      Store.put(__MODULE__, "follows", %{"alice" => %{"at" => 1725000000}})
      Store.get(__MODULE__, "follows", %{})
      Store.update(__MODULE__, "count", 0, &(&1 + 1))
  """
  use GenServer
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def data_dir do
    Application.get_env(:bowser_brain, :data_dir, Path.join(System.user_home!(), ".bowser/data"))
  end

  @doc "Every key/value this mod has stored (empty map when none)."
  def all(mod), do: GenServer.call(__MODULE__, {:all, scope(mod)})

  def get(mod, key, default \\ nil), do: Map.get(all(mod), to_string(key), default)

  @doc "Persist one value. `{:error, reason}` when the value is not JSON-shaped; nothing is written then."
  def put(mod, key, value), do: GenServer.call(__MODULE__, {:put, scope(mod), to_string(key), value})

  @doc "Read-modify-write in one step: `{:ok, new_value}`."
  def update(mod, key, default, fun) when is_function(fun, 1) do
    GenServer.call(__MODULE__, {:update, scope(mod), to_string(key), default, fun})
  end

  def delete(mod, key), do: GenServer.call(__MODULE__, {:delete, scope(mod), to_string(key)})

  @doc "Forget everything this mod stored (file removed)."
  def clear(mod), do: GenServer.call(__MODULE__, {:clear, scope(mod)})

  @doc "File-safe scope for a mod: `PageToolsMod` -> \"PageToolsMod\"; strings are sanitized."
  def scope(mod) when is_atom(mod), do: mod |> inspect() |> scope()

  def scope(mod) when is_binary(mod) do
    mod
    |> String.replace_prefix("Elixir.", "")
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
  end

  # -- server --------------------------------------------------------------

  @impl true
  def init(nil), do: {:ok, %{cache: %{}}}

  @impl true
  def handle_call({:all, scope}, _from, state) do
    {map, state} = load(state, scope)
    {:reply, map, state}
  end

  def handle_call({:put, scope, key, value}, _from, state) do
    {map, state} = load(state, scope)
    write(state, scope, Map.put(map, key, value))
  end

  def handle_call({:update, scope, key, default, fun}, _from, state) do
    {map, state} = load(state, scope)
    value = fun.(Map.get(map, key, default))

    case write(state, scope, Map.put(map, key, value)) do
      {:reply, :ok, state} -> {:reply, {:ok, value}, state}
      other -> other
    end
  end

  def handle_call({:delete, scope, key}, _from, state) do
    {map, state} = load(state, scope)
    write(state, scope, Map.delete(map, key))
  end

  def handle_call({:clear, scope}, _from, state) do
    File.rm(path(scope))
    {:reply, :ok, %{state | cache: Map.delete(state.cache, scope)}}
  end

  defp load(%{cache: cache} = state, scope) do
    case cache do
      %{^scope => map} ->
        {map, state}

      _ ->
        map =
          with {:ok, raw} <- File.read(path(scope)),
               {:ok, decoded} when is_map(decoded) <- JSON.decode(raw) do
            decoded
          else
            _ -> %{}
          end

        {map, %{state | cache: Map.put(cache, scope, map)}}
    end
  end

  # Encode BEFORE touching the file: a value JSON can't take (a tuple, a
  # pid) is refused, and the previous contents stay intact on disk.
  defp write(state, scope, map) do
    case safe_encode(map) do
      {:ok, json} ->
        file = path(scope)
        File.mkdir_p!(Path.dirname(file))
        tmp = file <> ".tmp"
        File.write!(tmp, json)
        File.rename!(tmp, file)
        {:reply, :ok, %{state | cache: Map.put(state.cache, scope, map)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp safe_encode(map) do
    {:ok, JSON.encode!(map)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp path(scope), do: Path.join(data_dir(), scope <> ".json")
end
