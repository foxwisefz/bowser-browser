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

  @doc """
  Host scoping (bowser-browser-7md): should this event be dropped before it
  reaches a mod declared with `use BowserBrain.Mod, host: "x.com"`? Events
  carrying a url are matched directly (subdomains included, same rule as
  SiteMods); other webview events consult the Session mirror; events with
  no webview (hello, omnibar, chrome, surface) and UNKNOWN urls always pass
  — a brand-new tab must not break a mod's init flow.
  """
  def scoped_out?(_event, nil), do: false

  def scoped_out?(%{"url" => url}, host) when is_binary(url) do
    not on_host?(url, host)
  end

  def scoped_out?(%{"webview" => wv}, host) do
    case BowserBrain.Session.url_of(wv) do
      url when is_binary(url) -> not on_host?(url, host)
      _ -> false
    end
  end

  def scoped_out?(_event, _host), do: false

  defp on_host?(url, host) do
    case URI.parse(url).host do
      h when is_binary(h) -> h == host or String.ends_with?(h, "." <> host)
      _ -> true
    end
  end

  defmacro __using__(opts) do
    quote do
      use GenServer
      @behaviour BowserBrain.Mod
      @bowser_mod_host unquote(Keyword.get(opts, :host))

      def __bowser_mod__, do: true
      def __bowser_handoff__, do: unquote(Keyword.get(opts, :handoff, false))

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts,
          name: {:via, Registry, {BowserBrain.ModRegistry, __MODULE__}}
        )
      end

      @impl GenServer
      def init(opts) do
        {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
        case Application.get_env(:bowser_brain, :handoff_mod_states, %{}) do
          %{__MODULE__ => state} -> {:ok, state}
          _ -> {:ok, init_mod(opts)}
        end
      end

      @impl GenServer
      def handle_info({:browser_event, event}, state) do
        if BowserBrain.Mod.scoped_out?(event, @bowser_mod_host) do
          {:noreply, state}
        else
          {:noreply, handle_event(event, state)}
        end
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
