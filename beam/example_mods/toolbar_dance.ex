# The owner's ask, literal edition: music notes floating up over the REAL
# browser toolbar while YouTube Music plays. An injected detector streams
# play-state via window.bowser.emit; this mod drives a :toolbar_overlay
# surface with the particles widget.
defmodule ToolbarDanceMod do
  use BowserBrain.Mod, handoff: true
  import BowserBrain.View
  alias BowserBrain.{Page, Surface}

  @detector """
  (function () {
    if (location.hostname !== "music.youtube.com") return;
    var last = null;
    setInterval(function () {
      var v = document.querySelector("video");
      var playing = !!(v && !v.paused && !v.ended && v.currentTime > 0);
      if (playing !== last) {
        last = playing;
        window.bowser && window.bowser.emit({ kind: "yt_play", playing: playing });
      }
    }, 800);
  })();
  """

  def init_mod(_opts) do
    Page.set_scripts([@detector], reload: false)
    %{playing: false}
  end

  def handle_event(%{"event" => "hello"}, state) do
    Page.set_scripts([@detector], reload: false)
    render(%{state | playing: false})
  end

  def handle_event(%{"event" => "mod_reloaded"}, state) do
    Page.set_scripts([@detector])
    state
  end

  def handle_event(%{"event" => "page", "payload" => %{"kind" => "yt_play", "playing" => playing}}, state) do
    if playing == state.playing, do: state, else: render(%{state | playing: playing})
  end

  def handle_event(_event, state), do: state

  defp render(state) do
    Surface.show(
      :toolbar_dance,
      particles(chars: ["♪", "♫", "♩", "♬"], rate: 3.0, active: state.playing),
      kind: :toolbar_overlay
    )

    state
  end
end
