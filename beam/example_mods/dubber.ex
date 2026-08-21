# Live voice dubbing, brain half v1.2 (bowser-browser-dku): `:dub` on a
# YouTube watch page fetches the video's AUDIO directly (yt-dlp on this
# machine — both in-page capture paths are dead on WebKit), cuts it into
# 20s segments (ffmpeg), runs each through OpenAI translations (whisper-1:
# any language in, English text out) + TTS, and streams time-stamped mp3s
# to the page's synchronized player. Segments are cached per video URL, so
# re-watching or reloading is free. Key via `:set openai_api_key`.
# Capped at 45 segments (15 min) per video to bound cost — logged if hit.
defmodule DubberMod do
  use BowserBrain.Mod, host: "youtube.com"

  alias BowserBrain.{Chrome, ModLog, Page, Session, Settings}

  @seg_seconds 20
  @max_segments 45

  def init_mod(_opts) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
    assert_chrome()
    %{active: 0, on: MapSet.new(), jobs: %{}, cache: %{}}
  end

  def handle_event(%{"event" => "hello"} = hello, state) do
    assert_chrome()

    state
    |> Map.put(:active, Map.get(hello, "active", Map.get(state, :active, 0)))
    |> Map.put(:on, MapSet.new())
    |> Map.put_new(:jobs, %{})
    |> Map.put_new(:cache, %{})
  end

  def handle_event(%{"event" => "tab_activated", "webview" => wv}, state) do
    %{state | active: wv}
  end

  def handle_event(%{"event" => "omnibar_command", "text" => "dub"}, state) do
    wv = state.active

    cond do
      Settings.get("openai_api_key") in [nil, ""] ->
        ModLog.log("dubber", "no key — :set openai_api_key first")
        state

      true ->
        page_on =
          case page_eval(wv, "window.__bowserDub ? JSON.parse(window.__bowserDub.status()).on : null") do
            {:ok, value} -> value
            _ -> nil
          end

        case page_on do
          nil ->
            ModLog.log("dubber", "wv#{wv}: dub.js not present (not a youtube page?)")
            state

          true ->
            page_eval(wv, "window.__bowserDub.stop()")
            ModLog.log("dubber", "wv#{wv}: dubbing OFF")
            %{state | on: MapSet.delete(state.on, wv)}

          false ->
            page_eval(wv, "window.__bowserDub.start()")
            state = %{state | on: MapSet.put(state.on, wv)}
            arm(wv, state)
        end
    end
  end

  # A dubbed tab reloaded or SPA-navigated: re-arm the player (retrying —
  # the payload injects at document END, well after url_changed).
  def handle_event(%{"event" => "url_changed", "webview" => wv}, state) do
    if MapSet.member?(state.on, wv), do: Process.send_after(self(), {:reassert, wv, 6}, 1_500)
    state
  end

  # Audio arrives from the page in base64 parts; when complete, the ffmpeg ->
  # whisper -> tts pipeline takes over in a Task.
  def handle_event(
        %{"event" => "page", "webview" => wv,
          "payload" => %{"kind" => "dub_audio", "part" => part, "total" => total, "data" => b64}},
        state
      ) do
    url = Session.url_of(wv) || ""
    jobs = Map.get(state, :jobs, %{})

    case Map.get(jobs, url) do
      %{parts: parts} = job ->
        {:ok, bin} = Base.decode64(b64)
        parts = Map.put(parts, part, bin)
        job = %{job | parts: parts, total: total}

        if map_size(parts) == total do
          audio = Enum.map_join(0..(total - 1), "", &Map.fetch!(parts, &1))
          ModLog.log("dubber", "wv#{wv}: audio assembled (#{div(byte_size(audio), 1_000_000)}MB) — segmenting")
          key = Settings.get("openai_api_key")
          parent = self()
          Task.start(fn -> process_audio(parent, wv, url, key, audio) end)
        end

        Map.put(state, :jobs, Map.put(jobs, url, job))

      _ ->
        state
    end
  end

  def handle_event(
        %{"event" => "page", "webview" => wv, "payload" => %{"kind" => "dub_log", "msg" => msg}},
        state
      ) do
    ModLog.log("dubber", "wv#{wv} page: #{msg}")
    state
  end

  def handle_event(_event, state), do: state

  def handle_info({:reassert, wv, tries}, state) do
    if MapSet.member?(state.on, wv) do
      case page_eval(wv, "window.__bowserDub ? window.__bowserDub.start() : null") do
        {:ok, "dubbing on"} ->
          ModLog.log("dubber", "wv#{wv}: re-armed after navigation")
          {:noreply, arm(wv, state)}

        {:ok, "already on"} ->
          {:noreply, state}

        _other when tries > 1 ->
          Process.send_after(self(), {:reassert, wv, tries - 1}, 2_000)
          {:noreply, state}

        other ->
          ModLog.log("dubber", "wv#{wv}: re-arm gave up #{inspect(other)}")
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:segment, wv, url, t0, mp3_b64}, state) do
    cache = Map.update(Map.get(state, :cache, %{}), url, [{t0, mp3_b64}], &[{t0, mp3_b64} | &1])
    deliver(wv, t0, mp3_b64)
    {:noreply, Map.put(state, :cache, cache)}
  end

  def handle_info({:job_done, wv, url, outcome}, state) do
    ModLog.log("dubber", "wv#{wv}: job #{outcome} (#{length(Map.get(state.cache, url, []))} segments)")
    {:noreply, Map.put(state, :jobs, Map.delete(Map.get(state, :jobs, %{}), url))}
  end

  def handle_info(other, state), do: super(other, state)

  # -- the pipeline ------------------------------------------------------------

  # Arm a tab: cached segments replay instantly; otherwise one fetch job per
  # video URL runs in the background.
  defp arm(wv, state) do
    url = Session.url_of(wv) || ""
    cache = Map.get(state, :cache, %{})
    jobs = Map.get(state, :jobs, %{})

    cond do
      not String.contains?(url, "/watch") ->
        ModLog.log("dubber", "wv#{wv}: not a watch page — nothing to dub")
        state

      Map.has_key?(cache, url) ->
        for {t0, b64} <- Enum.sort(Map.get(cache, url, [])), do: deliver(wv, t0, b64)
        ModLog.log("dubber", "wv#{wv}: replayed #{length(Map.get(cache, url, []))} cached segments")
        state

      Map.has_key?(jobs, url) ->
        state

      true ->
        # The BROWSER fetches: it is already cookied and authorized for this
        # exact stream — no anti-bot walls (external yt-dlp drew 403s).
        page_eval(wv, "window.__bowserDub && window.__bowserDub.fetchAudio()")
        ModLog.log("dubber", "wv#{wv}: asked the page to fetch its audio…")
        Map.put(state, :jobs, Map.put(jobs, url, %{wv: wv, parts: %{}, total: nil}))
    end
  end

  defp deliver(wv, t0, mp3_b64) do
    payload = if mp3_b64, do: ~s("#{mp3_b64}"), else: "null"
    BowserBrain.Browser.eval_js("window.__bowserDub && window.__bowserDub.deliver(#{t0}, #{payload})", wv)
  end

  defp process_audio(parent, wv, url, key, audio_binary) do
    dir = Path.join(System.tmp_dir!(), "bowser-dub-#{:erlang.phash2(url)}")
    File.mkdir_p!(dir)
    audio = Path.join(dir, "audio.m4a")
    File.write!(audio, audio_binary)

    with {_, 0} <-
           System.cmd("/opt/homebrew/bin/ffmpeg",
             ["-y", "-loglevel", "error", "-i", audio, "-vn", "-f", "segment",
              "-segment_time", "#{@seg_seconds}", "-ar", "16000", "-ac", "1",
              "-c:a", "libmp3lame", "-b:a", "48k", Path.join(dir, "seg%03d.mp3")],
             stderr_to_stdout: true) do
      segments = dir |> Path.join("seg*.mp3") |> Path.wildcard() |> Enum.sort()
      capped = Enum.take(segments, @max_segments)

      if length(segments) > @max_segments do
        send_log(parent, wv, "video longer than #{@max_segments * @seg_seconds}s — dubbing the first 15min")
      end

      send_log(parent, wv, "audio fetched: #{length(capped)} segments to translate")

      capped
      |> Enum.with_index()
      |> Enum.each(fn {seg_path, idx} ->
        t0 = idx * @seg_seconds
        mp3 = File.read!(seg_path)

        result =
          with {:ok, text} <- translate(mp3, key),
               true <- String.trim(text) != "" || :empty,
               {:ok, tts} <- speak(text, key) do
            send_log(parent, wv, "#{t0}s: #{String.slice(text, 0, 40)}")
            Base.encode64(tts)
          else
            :empty -> nil
            error ->
              send_log(parent, wv, "#{t0}s FAILED: #{inspect(error) |> String.slice(0, 70)}")
              nil
          end

        send(parent, {:segment, wv, url, t0, result})
      end)

      File.rm_rf!(dir)
      send(parent, {:job_done, wv, url, "done"})
    else
      {output, code} ->
        send_log(parent, wv, "ffmpeg failed (#{code}): #{String.slice(to_string(output), 0, 160)}")
        File.rm_rf!(dir)
        send(parent, {:job_done, wv, url, "failed"})
    end
  end

  defp send_log(parent, wv, msg) do
    ModLog.log("dubber", "wv#{wv}: #{msg}")
    _ = parent
    :ok
  end

  defp page_eval(wv, js) do
    Page.eval(js, webview: wv)
  catch
    :exit, _ -> {:error, :timeout}
  end

  defp translate(audio, key) do
    boundary = "bowserdub#{System.unique_integer([:positive])}"
    body = multipart(boundary, audio)

    request(
      :post,
      ~c"https://api.openai.com/v1/audio/translations",
      [{~c"authorization", String.to_charlist("Bearer " <> key)}],
      String.to_charlist("multipart/form-data; boundary=#{boundary}"),
      body
    )
    |> case do
      {:ok, response} -> parse_translation(response)
      error -> error
    end
  end

  defp speak(text, key) do
    body =
      JSON.encode!(%{model: "tts-1", voice: "alloy", input: String.slice(text, 0, 4000),
                     response_format: "mp3", speed: 1.08})

    request(
      :post,
      ~c"https://api.openai.com/v1/audio/speech",
      [{~c"authorization", String.to_charlist("Bearer " <> key)}],
      ~c"application/json",
      body
    )
  end

  defp request(method, url, headers, content_type, body) do
    case :httpc.request(
           method,
           {url, headers, content_type, IO.iodata_to_binary(body)},
           [timeout: 60_000, connect_timeout: 8_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, response}} -> {:ok, response}
      {:ok, {{_, code, _}, _headers, response}} -> {:error, {code, String.slice(response, 0, 200)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- pure helpers (public for tests) ----------------------------------------

  @doc "Multipart body for whisper: the audio file + model field."
  def multipart(boundary, audio) do
    [
      "--#{boundary}\r\n",
      "Content-Disposition: form-data; name=\"file\"; filename=\"chunk.mp3\"\r\n",
      "Content-Type: audio/mpeg\r\n\r\n",
      audio,
      "\r\n--#{boundary}\r\n",
      "Content-Disposition: form-data; name=\"model\"\r\n\r\n",
      "whisper-1",
      "\r\n--#{boundary}--\r\n"
    ]
  end

  @doc "The English text out of a translations response."
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
