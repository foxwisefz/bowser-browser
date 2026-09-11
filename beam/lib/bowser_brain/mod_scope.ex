defmodule BowserBrain.ModScope do
  @moduledoc "Profile ownership for user mods. Core services remain unscoped."

  def source_profile(source) do
    case Regex.run(~r/^(?:#|\/\/|\/\*) bowser-profile: ([A-Za-z0-9_-]+)(?: \*\/)?$/m, source) do
      [_, profile] -> profile
      _ -> "default"
    end
  end

  def file_profile(path) do
    case File.read(path) do
      {:ok, source} -> source_profile(source)
      _ -> "default"
    end
  end

  def tag(source, profile, ext \\ ".ex") do
    prefix = case ext do
      ".css" -> "/* bowser-profile: #{profile} */\n"
      ".js" -> "// bowser-profile: #{profile}\n"
      _ -> "# bowser-profile: #{profile}\n"
    end
    prefix <>
      Regex.replace(~r/^(?:#|\/\/|\/\*) bowser-profile: .*\n?/m, source, "")
  end

  def current(pid \\ self()) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :bowser_profile)
      _ -> nil
    end
  end

  def profile_of(webview) do
    state = :sys.get_state(BowserBrain.Session)
    Map.get(Map.get(state, :profiles, %{}), webview, "default")
  catch
    :exit, _ -> "default"
  end

  def active do
    state = :sys.get_state(BowserBrain.Session)
    Map.get(Map.get(state, :profiles, %{}), state.active, "default")
  catch
    :exit, _ -> "default"
  end

  def filter(%{"event" => "hello"} = event, profile) do
    tabs = Enum.filter(event["tabs"] || [], &((&1["profile"] || "default") == profile))
    ids = Enum.map(tabs, &(&1["id"] || &1["webview"]))
    event |> Map.put("tabs", tabs) |> Map.put("webviews", ids)
      |> Map.put("active", if(event["active"] in ids, do: event["active"], else: List.first(ids)))
  end
  def filter(%{"event" => "mod_reloaded"} = event, _profile), do: event
  def filter(event, profile) do
    if (event["profile"] || profile_of(event["webview"])) == profile do
      case event["surface"] do
        surface when is_binary(surface) -> Map.put(event, "surface", String.replace_prefix(surface, "profile:#{profile}:", ""))
        _ -> event
      end
    end
  end

  def surface_id(id) do
    if profile = current(), do: "profile:#{profile}:#{id}", else: to_string(id)
  end

  def outgoing(map) do
    case current() do
      nil -> map
      profile -> Map.put(map, :profile, profile)
    end
  end
end
