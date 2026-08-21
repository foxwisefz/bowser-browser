# Live voice dubbing, brain half (bowser-browser-dku): `:dub` toggles the
# current YouTube tab. The page emits standalone 6s audio chunks; each goes
# to OpenAI translations (whisper-1 — speech in any language OUT as English
# text) then /audio/speech (TTS), and the mp3 is delivered back to the
# page's in-order playback queue. Key via `:set openai_api_key` (Settings,
# secret). A consecutive interpreter ~8s behind live; Realtime S2S is v2.
defmodule DubberMod do
  use BowserBrain.Mod, host: "youtube.com"

  alias BowserBrain.{Browser, Chrome, ModLog, Page, Settings}

  def init_mod(_opts) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
    assert_chrome()
    %{active: 0, on: MapSet.new()}
  end

  def handle_event(%{"event" => "hello"} = hello, state) do
    assert_chrome()
    %{state | active: Map.get(hello, "active", Map.get(state, :active, 0)), on: MapSet.new()}
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
        # The PAGE is the truth: after a reload the page half resets to off
        # while the brain's set still says on — blind toggling then inverts
        # and every :dub does the opposite of what the owner meant
        # (bowser-browser-h9i).
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
            ModLog.log("dubber", "wv#{wv}: dubbing ON")
            %{state | on: MapSet.put(state.on, wv)}
        end
    end
  end

  # A dubbed tab reloaded or SPA-navigated to the next video: the page half
  # reset to off. Re-assert start after the payload has injected — start()
  # is idempotent, so a still-running session is untouched.
  def handle_event(%{"event" => "url_changed", "webview" => wv}, state) do
    if MapSet.member?(state.on, wv), do: Process.send_after(self(), {:reassert, wv}, 1_500)
    state
  end

  def handle_event(
        %{"event" => "page", "webview" => wv,
          "payload" => %{"kind" => "dub_chunk", "seq" => seq, "data" => b64}},
        state
      ) do
    if MapSet.member?(state.on, wv) do
      key = Settings.get("openai_api_key")
      parent = self()

      Task.start(fn ->
        result = dub_chunk(b64, key)
        send(parent, {:deliver, wv, seq, result})
      end)
    end

    state
  end

  def handle_event(_event, state), do: state

  def handle_info({:reassert, wv}, state) do
    if MapSet.member?(state.on, wv) do
      case page_eval(wv, "window.__bowserDub ? window.__bowserDub.start() : null") do
        {:ok, "dubbing on"} -> ModLog.log("dubber", "wv#{wv}: re-armed after navigation")
        {:ok, "already on"} -> :ok
        other -> ModLog.log("dubber", "wv#{wv}: re-arm failed #{inspect(other)}")
      end
    end

    {:noreply, state}
  end

  def handle_info({:deliver, wv, seq, result}, state) do
    payload =
      case result do
        {:ok, mp3_b64} -> ~s("#{mp3_b64}")
        _ -> "null"
      end

    Browser.eval_js("window.__bowserDub && window.__bowserDub.deliver(#{seq}, #{payload})", wv)
    {:noreply, state}
  end

  def handle_info(other, state), do: super(other, state)

  # -- the pipeline ------------------------------------------------------------

  defp dub_chunk(b64, key) do
    t0 = System.monotonic_time(:millisecond)

    with {:ok, audio} <- Base.decode64(b64),
         {:ok, text} <- translate(audio, key),
         t1 = System.monotonic_time(:millisecond),
         true <- String.trim(text) != "" || {:skip, :empty},
         {:ok, mp3} <- speak(text, key) do
      t2 = System.monotonic_time(:millisecond)

      ModLog.log(
        "dubber",
        "ok (#{t1 - t0}ms whisper, #{t2 - t1}ms tts): #{String.slice(text, 0, 40)}"
      )

      {:ok, Base.encode64(mp3)}
    else
      {:skip, :empty} ->
        ModLog.log("dubber", "chunk had no speech — skipped")
        :skip

      other ->
        ModLog.log("dubber", "chunk FAILED: #{inspect(other) |> String.slice(0, 80)}")
        :skip
    end
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
                     response_format: "mp3", speed: 1.1})

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
           [timeout: 30_000, connect_timeout: 8_000],
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
      "Content-Disposition: form-data; name=\"file\"; filename=\"chunk.webm\"\r\n",
      "Content-Type: audio/webm\r\n\r\n",
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
