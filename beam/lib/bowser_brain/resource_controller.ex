defmodule BowserBrain.ResourceController do
  @moduledoc """
  Supervised browser policy over native-owned resources. All pending intents and
  operation receipts stay native, so this controller can restart without replaying
  completed effects. Decisions are pure and always use the supplied topology.
  """
  use BowserBrain.CoreFeature
  def initial_state do
    Process.send_after(self(), :ready, 1_000)
    %{}
  end
  def handle_info(:ready, state) do
    BowserBrain.Bridge.cast_msg(%{op: "resource_snapshot"})
    Process.send_after(self(), :ready, 1_000)
    {:noreply, state}
  end
  def handle_info(message, state), do: super(message, state)
  def handle_event(%{"event" => "hello", "resources" => snapshot}, state), do: publish(snapshot, state)
  def handle_event(%{"event" => "resources", "snapshot" => snapshot}, state), do: publish(snapshot, state)
  def handle_event(%{"event" => "resource_intent"} = event, state) do
    BowserBrain.Bridge.cast_msg(decision(event))
    state
  end
  def handle_event(_, state), do: state

  defp publish(snapshot, state) do
    BowserBrain.Bridge.cast_msg(%{op: "resource_policy", version: 1, session: snapshot["session"], navigation: navigation_rules()})
    BowserBrain.Bridge.cast_msg(%{op: "resource_ready"})
    state
  end
  def navigation_rules do
    [%{required: ["command", "shift"], forbidden: [], action: "foreground_tab"},
     %{required: ["command"], forbidden: [], action: "background_tab"}]
  end
  def download_filename(suggested) do
    name = suggested |> String.replace("\\", "/") |> String.split("/") |> List.last() |> String.replace(~r/[\p{Cc}\p{Cf}]/u, "") |> String.slice(0, 180)
    if name in ["", ".", ".."], do: "download", else: name
  end
  def decision(%{"request" => request, "intent" => %{"action" => "download_destination", "download" => id}, "snapshot" => snapshot}) do
    base = %{op: "resource_decision", request: request, version: 1, session: snapshot["session"], sequence: snapshot["next"]}
    case Enum.find(Map.get(snapshot, "downloads", []), &(&1["id"] == id && &1["awaiting_destination"])) do
      nil -> Map.put(base, :discard, true)
      download -> Map.put(base, :command, %{action: "download_destination", download: id, profile: download["profile"],
          revision: snapshot["revision"], filename: download_filename(download["suggested"])})
    end
  end

  def decision(%{"request" => request, "intent" => intent, "snapshot" => snapshot}) do
    tab = intent["tab"]
    window = Enum.find(snapshot["windows"], &(tab in &1["tabs"]))
    base = %{op: "resource_decision", request: request, version: 1, session: snapshot["session"], sequence: snapshot["next"]}
    if window do
      case tab_command(intent, window) do
        nil -> Map.put(base, :discard, true)
        command -> Map.put(base, :command, Map.merge(command, %{revision: snapshot["revision"], window: window["id"], profile: window["profile"], tab: tab}))
      end
    else
      Map.put(base, :discard, true)
    end
  end

  def tab_command(intent, window) do
    order = window["tabs"]
    tab = intent["tab"]
    active = window["active"]
    case intent["action"] do
      "activate" -> %{action: "arrange", order: order, active: tab, focus_page: Map.get(intent, "focus_page", true)}
      "cycle" ->
        index = Enum.find_index(order, &(&1 == active)) || 0
        %{action: "arrange", order: order, active: Enum.at(order, Integer.mod(index + intent["offset"], length(order)))}
      "move" ->
        target = intent["target"]
        if target in order and target != tab, do: %{action: "move", target: target, after: intent["after"]}
      "opened" ->
        rest = List.delete(order, tab)
        anchor = Enum.find_index(rest, &(&1 == intent["anchor"]))
        position = if intent["append"] || is_nil(anchor), do: length(rest), else: anchor + 1
        %{action: "arrange", order: List.insert_at(rest, position, tab), active: if(intent["activate"], do: tab, else: active)}
      "close" ->
        rest = List.delete(order, tab)
        panes = List.delete(Map.get(window, "panes", []), tab)
        next = cond do
          active != tab -> active
          panes != [] -> hd(panes)
          rest == [] -> nil
          true -> Enum.at(rest, min(Enum.find_index(order, &(&1 == tab)), length(rest) - 1))
        end
        %{action: "close", active: next}
      _ -> nil
    end
  end
end
