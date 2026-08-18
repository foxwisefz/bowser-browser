# Background media cold-start (bowser-browser-hj1): after an engine death,
# a media page restored into a BACKGROUND tab never rebuilds its player —
# WebKit defers media pipeline work for webviews that aren't in a window, so
# the site's resume script stalls and the music stays silent.
#
# This mod is the generic half: on every page load, ask the page whether the
# engine-level media hook left a FRESH snapshot of PLAYING media. If so, warm
# the tab — the shell mounts it invisibly under the active tab for a few
# seconds, which is enough for the site's play-click payload (see
# sites/music.youtube.com/resume.js) to rebuild the stream. Once audio is
# rolling, unmounting doesn't stop it.
defmodule MediaWarmMod do
  use BowserBrain.Mod

  # Mirrors EngineView.mediaResumeWindowSeconds (120s) and the snapshot key
  # scheme in the shell's media hook.
  @fresh_ms 120_000
  @warm_ms 10_000

  @snapshot_js """
  localStorage.getItem("bowser-media:" + location.host + location.pathname)
  """

  def handle_event(%{"event" => "load_status", "status" => 2, "webview" => wv}, state) do
    raw =
      try do
        case BowserBrain.Bridge.eval_js(wv, @snapshot_js) do
          {:ok, value} -> value
          _ -> nil
        end
      catch
        :exit, _ -> nil
      end

    if resumable?(raw, System.system_time(:millisecond)) do
      IO.puts("[media_warm] webview #{wv}: fresh playing snapshot — warming tab")
      BowserBrain.Bridge.cast_msg(%{op: "warm_tab", webview: wv, ms: @warm_ms})
    end

    state
  end

  def handle_event(_event, state), do: state

  @doc "Fresh (<2min) snapshot of media that was PLAYING when the engine died?"
  def resumable?(raw, now_ms) when is_binary(raw) do
    case JSON.decode(raw) do
      {:ok, %{"paused" => false, "at" => at}} when is_number(at) ->
        now_ms - at < @fresh_ms

      _ ->
        false
    end
  end

  def resumable?(_raw, _now_ms), do: false
end
