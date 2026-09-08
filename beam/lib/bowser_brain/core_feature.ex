defmodule BowserBrain.CoreFeature do
  @moduledoc "Named, built-in browser services. No user-mod registry, loader or initialization side effects."
  defmacro __using__(_opts) do
    quote do
      use GenServer
      def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
      @impl true
      def init(nil) do
        Registry.register(BowserBrain.Events, :browser_event, nil)
        {:ok, initial_state()}
      end
      @impl true
      def handle_info({:browser_event, event}, state), do: {:noreply, handle_event(event, state)}
      def handle_info(_, state), do: {:noreply, state}
      defoverridable handle_info: 2
    end
  end
end
