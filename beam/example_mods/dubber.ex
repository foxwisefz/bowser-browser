# Live voice dubbing v2, brain half (bowser-browser-gj9): `:dub` on a
# YouTube watch page tells the SHELL to capture the browser's own audio
# OUTPUT (ScreenCaptureKit) — defeating every stream protection because we
# hear what the user hears. The shell streams 6s 16kHz WAV chunks; each goes
# through OpenAI translations (whisper-1: any language in, English out) then
# TTS, and the shell plays the English back in its own process (excluded
# from capture, so no feedback loop). Key via `:set openai_api_key`.
# A consecutive interpreter ~8s behind live. curl for HTTP (this OTP ships
# no usable inets).
defmodule DubberMod do
  use BowserBrain.Mod, host: "youtube.com"

  alias BowserBrain.{Bridge, Chrome, ModLog, Page, Settings}

  def init_mod(_opts) do
    assert_chrome()
    %{active: 0, on: false, muzzle_until: 0}
  end

  def handle_event(%{"event" => "hello"} = hello, state) do
    assert_chrome()
    %{active: Map.get(hello, "active", Map.get(state, :active, 0)), on: false, muzzle_until: 0}
  end

  def handle_event(%{"event" => "tab_activated", "webview" => wv}, state) do
    %{state | active: wv}
  end

  def handle_event(%{"event" => "omnibar_command", "text" => "dub"}, state) do
    cond do
      Settings.get("openai_api_key") in [nil, "", "<null>"] ->
        ModLog.log("dubber", "no key — :set openai_api_key first")
        state

      state.on ->
        Bridge.cast_msg(%{op: "dub_capture_stop"})
        duck(state.active, false)
        ModLog.log("dubber", "dubbing OFF")
        %{state | on: false}

      true ->
        Bridge.cast_msg(%{op: "dub_capture_start"})
        duck(state.active, true)
        ModLog.log("dubber", "dubbing ON — capturing browser audio (grant screen-recording if asked)")
        %{state | on: true}
    end
  end

  # A 16kHz WAV chunk of the browser's own audio, from the shell.
  def handle_event(%{"event" => "dub_audio_chunk", "seq" => seq, "data" => wav_b64}, state) do
    now = System.system_time(:millisecond)

    cond do
      not state.on ->
        state

      # Muzzle: while our own TTS is (about to be) playing, the captured
      # audio is dominated by the dub — translating it would loop. Skip.
      now < Map.get(state, :muzzle_until, 0) ->
        ModLog.log("dubber", "#{seq}: muzzled (dub playing)")
        state

      true ->
        key = Settings.get("openai_api_key")
        parent = self()
        Task.start(fn -> pipeline(parent, seq, wav_b64, key) end)
        state
    end
  end

  def handle_event(%{"event" => "dub_capture_error", "message" => msg}, state) do
    ModLog.log("dubber", "capture error: #{msg}")
    %{state | on: false}
  end

  def handle_event(%{"event" => "dub_capture_status", "message" => msg}, state) do
    ModLog.log("dubber", msg)
    state
  end

  def handle_event(_event, state), do: state

  def handle_info({:play, seq, mp3_b64}, state) do
    if state.on do
      Bridge.cast_msg(%{op: "dub_play", seq: seq, data: mp3_b64})
      until = System.system_time(:millisecond) + 7_000
      {:noreply, %{state | muzzle_until: until}}
    else
      {:noreply, state}
    end
  end

  def handle_info(other, state), do: super(other, state)

  # -- pipeline ---------------------------------------------------------------

  defp pipeline(parent, seq, wav_b64, key) do
    t0 = System.monotonic_time(:millisecond)

    with {:ok, wav} <- Base.decode64(wav_b64),
         path = write_temp(wav),
         {:ok, text} <- translate(path, key),
         _ = File.rm(path),
         true <- String.trim(text) != "" || :empty,
         t1 = System.monotonic_time(:millisecond),
         {:ok, mp3} <- speak(text, key) do
      t2 = System.monotonic_time(:millisecond)
      ModLog.log("dubber", "#{seq}: (#{t1 - t0}ms whisper, #{t2 - t1}ms tts) #{String.slice(text, 0, 42)}")
      send(parent, {:play, seq, Base.encode64(mp3)})
    else
      :empty -> ModLog.log("dubber", "#{seq}: silence — skipped")
      error -> ModLog.log("dubber", "#{seq} FAILED: #{inspect(error) |> String.slice(0, 90)}")
    end
  end

  defp write_temp(wav) do
    path = Path.join(System.tmp_dir!(), "bowser-dub-#{System.unique_integer([:positive])}.wav")
    File.write!(path, wav)
    path
  end

  defp duck(wv, on) do
    js =
      if on,
        do: "var v=document.querySelector('video'); if(v){v.dataset.dubVol=v.volume;v.volume=0.15;}",
        else: "var v=document.querySelector('video'); if(v){v.volume=(v.dataset.dubVol||1);}"

    Page.eval(js, webview: wv)
  catch
    :exit, _ -> :ok
  end

  defp translate(seg_path, key) do
    curl([
      "-H", "Authorization: Bearer #{key}",
      "-F", "file=@#{seg_path};type=audio/wav",
      "-F", "model=whisper-1",
      "https://api.openai.com/v1/audio/translations"
    ])
    |> case do
      {:ok, response} -> parse_translation(response)
      error -> error
    end
  end

  defp speak(text, key) do
    body =
      JSON.encode!(%{model: "tts-1", voice: "alloy", input: String.slice(text, 0, 4000),
                     response_format: "mp3", speed: 1.08})

    curl([
      "-H", "Authorization: Bearer #{key}",
      "-H", "Content-Type: application/json",
      "-d", body,
      "https://api.openai.com/v1/audio/speech"
    ])
  end

  defp curl(args) do
    case System.cmd("/usr/bin/curl", ["-sf", "--max-time", "90"] ++ args, stderr_to_stdout: true) do
      {body, 0} -> {:ok, body}
      {out, code} -> {:error, {:curl, code, String.slice(out, 0, 120)}}
    end
  end

  @doc "The English text out of a translations response. Public for tests."
  def parse_translation(response) do
    case JSON.decode(response) do
      {:ok, %{"text" => text}} -> {:ok, text}
      _ -> {:error, :bad_response}
    end
  end

  defp assert_chrome do
    Chrome.register_command("dub", "Dub this video's voice into English (toggle)")
    Settings.declare("openai_api_key", secret: true,
      about: "OpenAI key for the YouTube voice dubber (whisper translate + TTS)")
  end
end
