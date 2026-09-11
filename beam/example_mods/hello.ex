# Drop this file into ~/.bowser/mods/ (while the brain runs) and it goes live
# in under a second. Edit it there and save: the running process hot-swaps.
defmodule HelloMod do
  use BowserBrain.Mod, handoff: true

  def handle_event(%{"event" => "url_changed", "url" => url, "webview" => wv}, state) do
    IO.puts("[hello] webview #{wv} → #{url}")
    state
  end

  def handle_event(_event, state), do: state
end
