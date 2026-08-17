defmodule BowserBrain.Mod do
  @moduledoc """
  The mod behaviour. A mod is a supervised GenServer that receives browser
  events and drives the browser back through `BowserBrain.Browser`.

      defmodule MyMod do
        use BowserBrain.Mod

        def handle_event(%{"event" => "url_changed", "url" => url}, state) do
          IO.puts("now at " <> url)
          state
        end
      end

  Crash isolation: a raising callback kills only this mod's process; the
  supervisor restarts it. Hot reload: saving the mod's .ex file swaps its
  code into the running process on the next event (see BowserBrain.Loader).
  """

  @callback init_mod(term) :: term
  @callback handle_event(map, term) :: term

  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour BowserBrain.Mod

      def __bowser_mod__, do: true

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts,
          name: {:via, Registry, {BowserBrain.ModRegistry, __MODULE__}}
        )
      end

      @impl GenServer
      def init(opts) do
        {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
        {:ok, init_mod(opts)}
      end

      @impl GenServer
      def handle_info({:browser_event, event}, state) do
        {:noreply, handle_event(event, state)}
      end

      def handle_info(_other, state), do: {:noreply, state}

      @impl BowserBrain.Mod
      def init_mod(_opts), do: %{}

      @impl BowserBrain.Mod
      def handle_event(_event, state), do: state

      defoverridable init_mod: 1, handle_event: 2, handle_info: 2
    end
  end
end
