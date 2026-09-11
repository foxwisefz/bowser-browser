defmodule BowserServer.RateLimit do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def accept(client), do: GenServer.call(__MODULE__, {:accept, client})
  def reset, do: GenServer.call(__MODULE__, :reset)
  def init(_), do: {:ok, {0, %{}}}
  def handle_call(:reset, _, _), do: {:reply, :ok, {0, %{}}}

  def handle_call({:accept, client}, _, {window, counts}) do
    current = div(System.system_time(:millisecond), 60_000)
    counts = if current == window, do: counts, else: %{}
    count = Map.get(counts, client, 0)
    accepted = count < 20 and (count > 0 or map_size(counts) < 10_000)

    {:reply, accepted,
     {current, if(accepted, do: Map.put(counts, client, count + 1), else: counts)}}
  end
end
