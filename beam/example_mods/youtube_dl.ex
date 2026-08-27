# YouTube downloader (bowser-browser-0t3): `:dl` on a watch page saves the
# video to ~/Downloads. The browser provides the identity (its logged-in
# youtube.com cookies), yt-dlp provides the download engine that solves
# YouTube's nsig/SABR protection — the wall every raw-fetch approach hit.
# ffmpeg (already installed) merges best video + best audio.
defmodule YoutubeDlMod do
  use BowserBrain.Mod, host: "youtube.com"

  alias BowserBrain.{Bridge, Chrome, ModLog, Session}

  @ytdlp "/opt/homebrew/bin/yt-dlp"

  def init_mod(_opts) do
    Chrome.register_command("dl", "Download this video to ~/Downloads")
    %{active: 0}
  end

  def handle_event(%{"event" => "hello"} = hello, state) do
    Chrome.register_command("dl", "Download this video to ~/Downloads")
    %{active: Map.get(hello, "active", Map.get(state, :active, 0))}
  end

  def handle_event(%{"event" => "tab_activated", "webview" => wv}, state) do
    %{state | active: wv}
  end

  def handle_event(%{"event" => "omnibar_command", "text" => "dl"}, state) do
    url = Session.url_of(state.active) || ""

    cond do
      not File.exists?(@ytdlp) ->
        ModLog.log("yt-dl", "yt-dlp not found at #{@ytdlp}")

      not String.contains?(url, "/watch") ->
        ModLog.log("yt-dl", "not a watch page — open a video first")

      true ->
        ModLog.log("yt-dl", "downloading #{video_id(url)} (with your browser cookies)…")
        cookies = write_cookie_file()
        parent_log = self()
        _ = parent_log
        Task.start(fn -> run(url, cookies) end)
    end

    state
  end

  def handle_event(_event, state), do: state

  # -- the download ------------------------------------------------------------

  defp run(url, cookies) do
    out = Path.join([System.user_home!(), "Downloads", "%(title)s [%(id)s].%(ext)s"])

    args = [
      "--cookies", cookies,
      "--no-playlist",
      "--newline",
      "--no-part",
      # best video + best audio (ffmpeg-merged), falling back to best single.
      "-f", "bv*+ba/b",
      "--merge-output-format", "mp4",
      "-o", out,
      url
    ]

    case System.cmd(@ytdlp, args, stderr_to_stdout: true) do
      {output, 0} ->
        dest = final_path(output) || "~/Downloads"
        ModLog.log("yt-dl", "✓ saved: #{Path.basename(dest)}")

      {output, code} ->
        hint =
          cond do
            output =~ ~r/nsig|Signature|player.*js|throttl/i ->
              "yt-dlp's signature solver looks stale — run `yt-dlp -U` (or brew upgrade yt-dlp)"

            output =~ ~r/sign in|cookies|age|private/i ->
              "auth issue — make sure you're logged into youtube.com in Bowser"

            true ->
              last_meaningful(output)
          end

        ModLog.log("yt-dl", "✗ failed (#{code}): #{hint}")
    end
  after
    File.rm(cookies)
  end

  defp write_cookie_file do
    cookies =
      case safe_cookies() do
        {:ok, list} -> list
        _ -> []
      end

    path = Path.join(System.tmp_dir!(), "bowser-yt-cookies-#{System.unique_integer([:positive])}.txt")
    File.write!(path, netscape_cookies(cookies))
    path
  end

  defp safe_cookies do
    Bridge.get_cookies("https://www.youtube.com")
  catch
    :exit, _ -> {:error, :timeout}
  end

  # -- pure helpers (public for tests) ----------------------------------------

  @doc "Serialize engine cookies into a Netscape cookies.txt yt-dlp can read."
  def netscape_cookies(cookies) do
    header = "# Netscape HTTP Cookie File\n"

    body =
      Enum.map_join(cookies, "\n", fn c ->
        domain = c["domain"] || ".youtube.com"
        include_sub = if String.starts_with?(domain, "."), do: "TRUE", else: "FALSE"
        path = c["path"] || "/"
        secure = if c["secure"], do: "TRUE", else: "FALSE"
        # Far-future expiry so session cookies aren't dropped as expired.
        Enum.join([domain, include_sub, path, secure, "2147483647", c["name"], c["value"]], "\t")
      end)

    header <> body <> "\n"
  end

  @doc "The saved file path from yt-dlp's output (Destination / Merging lines)."
  def final_path(output) do
    lines = String.split(output, "\n")

    merged =
      Enum.find_value(lines, fn l ->
        case Regex.run(~r/Merging formats into "(.+)"/, l), do: ([_, p] -> p; _ -> nil)
      end)

    dest =
      Enum.find_value(lines, fn l ->
        case Regex.run(~r/\[download\] Destination: (.+)$/, l), do: ([_, p] -> p; _ -> nil)
      end)

    already =
      Enum.find_value(lines, fn l ->
        case Regex.run(~r/\[download\] (.+) has already been downloaded/, l),
          do: ([_, p] -> p; _ -> nil)
      end)

    merged || dest || already
  end

  defp video_id(url) do
    case Regex.run(~r/[?&]v=([\w-]+)/, url) do
      [_, id] -> id
      _ -> "video"
    end
  end

  defp last_meaningful(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find(fn l -> String.contains?(l, "ERROR") end)
    |> case do
      nil -> output |> String.split("\n", trim: true) |> List.last() || "unknown error"
      err -> err
    end
    |> String.slice(0, 140)
  end
end
