# Complete application, isolated runtime home; only the experiment observer is added.
[home, generation, behavior] = System.argv()
gen = String.to_integer(generation)
unless String.starts_with?(home, "/tmp/bowser-handoff.") or String.starts_with?(home, "/private/tmp/bowser-handoff."), do: raise("non-fixture home")
System.put_env("BOWSER_HOME", Path.join(home, "g#{gen}"))
System.put_env("BOWSER_NO_SPAWN", "1")
Application.load(:bowser_brain)
# Start every production child. Disable automatic connection until the observer
# is registered. This also prevents XServer opening the owner's shared port.
for {key, value} <- [connect_bridge: false, spawn_engine: false, watch_lib: false, watch_sites: false] do
  Application.put_env(:bowser_brain, key, value)
end
{:ok, _} = Application.ensure_all_started(:bowser_brain)

defmodule HandoffObserver do
  use GenServer
  def init({home, gen, behavior}) do
    Registry.register(BowserBrain.Events, :browser_event, nil)
    {:ok, %{home: home, gen: gen, behavior: behavior}}
  end
  def handle_info({:browser_event, %{"event" => "hello"} = hello}, s) do
    if s.behavior == "crash_on_attach", do: System.halt(86)
    owner = self()
    Task.start(fn ->
      # Calls act as barriers behind adoption and initial content handling.
      Process.sleep(30)
      session = :sys.get_state(BowserBrain.Session)
      tabs = hello["tabs"]
      view = Enum.find(tabs, &(Map.get(&1, "profile") == "handoff-work")) || hd(tabs)
      {:ok, value} = BowserBrain.Bridge.eval_js(view["id"], "window.controllerGeneration=#{s.gen};window.controllerGeneration")
      true = value == s.gen
      report = %{generation: s.gen, pid: System.pid(), children: length(Supervisor.which_children(BowserBrain.Supervisor)),
        tabs: session.tabs, profiles: session.profiles, active: session.active, restore: session.restore}
      File.write!(Path.join(s.home, "adopted-#{s.gen}.json"), JSON.encode!(report))
      send(owner, :adopted)
    end)
    {:noreply, s}
  end
  def handle_info({:browser_event, event}, s) do
    if seq = event["relay_seq"] do
      # Durable receipt BEFORE ack. This observer tests at-least-once replay;
      # it is not a transaction across arbitrary mods and their side effects.
      File.open!(Path.join(s.home, "receipts-#{s.gen}.jsonl"), [:append, :binary], fn file ->
        IO.binwrite(file, JSON.encode!(event) <> "\n")
        :file.sync(file)
      end)
      BowserBrain.Bridge.cast_msg(%{op: "experiment_ack", seq: seq})
    end
    {:noreply, s}
  end
  def handle_info(_, s), do: {:noreply, s}
end
{:ok, _} = GenServer.start_link(HandoffObserver, {home, gen, behavior})
File.write!(Path.join(home, "booted-#{gen}.json"), JSON.encode!(%{pid: System.pid(), protocol: if(behavior == "incompatible", do: 999, else: 1)}))
# The relay gates activation while this process is fully booted and warm.
send(BowserBrain.Bridge, :connect)
Process.sleep(:infinity)
