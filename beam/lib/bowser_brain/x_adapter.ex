defmodule BowserBrain.XAdapter do
  @moduledoc """
  X (Twitter) data adapter (bowser-browser-3fo): the de-risking spike for
  generated native apps on iOS. Proves the brain can turn the owner's
  logged-in x.com session into a CLEAN, structured tweet data model — the
  data layer every native declaration would render.

  No API (X killed third-party access): we read the live DOM the owner is
  already authenticated into, extracting each tweet in the timeline as a
  normalized map. Fragile by nature (X fights scraping) — this spike exists
  precisely to measure how fragile before anything is built on top.
  """

  alias BowserBrain.Page

  @extract """
  (function () {
    function txt(el, sel) { var n = el.querySelector(sel); return n ? n.innerText : null; }
    function metric(group, kind) {
      if (!group) return null;
      var el = group.querySelector('[data-testid="' + kind + '"]');
      var label = el && (el.getAttribute("aria-label") || el.innerText) || "";
      var m = /([\\d,.]+)\\s*[KMB]?/.exec(label);
      return m ? m[0].trim() : "0";
    }
    var cells = document.querySelectorAll('[data-testid="cellInnerDiv"]');
    var out = [];
    for (var i = 0; i < cells.length; i++) {
      var art = cells[i].querySelector("article");
      if (!art) continue;
      var text = txt(art, '[data-testid="tweetText"]');
      var permalinkA = art.querySelector('a[href*="/status/"]');
      var permalink = permalinkA ? permalinkA.getAttribute("href") : null;
      var idm = permalink && /\\/status\\/(\\d+)/.exec(permalink);
      var timeEl = art.querySelector("time");
      // User-Name block: "Display Name@handle·time" — split on the @.
      var nameBlock = txt(art, '[data-testid="User-Name"]') || "";
      var atIdx = nameBlock.indexOf("@");
      var handle = null, name = nameBlock;
      if (atIdx >= 0) {
        name = nameBlock.slice(0, atIdx).trim().split("\\n")[0];
        handle = "@" + (nameBlock.slice(atIdx + 1).split(/[·\\n]/)[0] || "").trim();
      }
      var photos = [];
      art.querySelectorAll('[data-testid="tweetPhoto"] img').forEach(function (img) {
        if (img.src) photos.push(img.src);
      });
      var group = art.querySelector('[role="group"]');
      out.push({
        id: idm ? idm[1] : null,
        name: name || null,
        handle: handle,
        text: text,
        permalink: permalink ? "https://x.com" + permalink : null,
        timestamp: timeEl ? timeEl.getAttribute("datetime") : null,
        photos: photos,
        has_video: !!art.querySelector('[data-testid="videoPlayer"], video'),
        metrics: {
          replies: metric(group, "reply"),
          reposts: metric(group, "retweet"),
          likes: metric(group, "like"),
          views: (function () {
            var a = art.querySelector('a[href$="/analytics"]');
            var m = a && /([\\d,.]+\\s*[KMB]?)/.exec(a.getAttribute("aria-label") || a.innerText || "");
            return m ? m[1].trim() : null;
          })()
        }
      });
    }
    return JSON.stringify(out);
  })()
  """

  @doc """
  Extract the currently-rendered timeline of a live x.com webview as a list
  of normalized tweet maps. `{:ok, [tweet]}` or `{:error, reason}`.
  """
  def timeline(webview) do
    with {:ok, json} when is_binary(json) <- safe_eval(webview),
         {:ok, raw} when is_list(raw) <- JSON.decode(json) do
      {:ok, normalize(raw)}
    else
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Clean the raw extraction: drop tweets with no id AND no text (ads,
  placeholders, dividers), dedupe by id, trim whitespace, and coerce the
  metric strings. Pure — the spike's testable core.
  """
  def normalize(raw) when is_list(raw) do
    raw
    |> Enum.filter(fn t -> present(t["id"]) or present(t["text"]) end)
    |> Enum.uniq_by(fn t -> t["id"] || t["permalink"] || t["text"] end)
    |> Enum.map(&normalize_one/1)
  end

  defp normalize_one(t) do
    %{
      id: t["id"],
      name: trim(t["name"]),
      handle: trim(t["handle"]),
      text: trim(t["text"]),
      permalink: t["permalink"],
      timestamp: t["timestamp"],
      photos: List.wrap(t["photos"]),
      has_video: t["has_video"] == true,
      metrics: %{
        replies: metric(t["metrics"], "replies"),
        reposts: metric(t["metrics"], "reposts"),
        likes: metric(t["metrics"], "likes"),
        views: metric(t["metrics"], "views")
      }
    }
  end

  defp metric(nil, _), do: "0"
  defp metric(m, k), do: (m[k] || "0") |> to_string() |> String.trim()

  defp present(v), do: is_binary(v) and String.trim(v) != ""
  defp trim(nil), do: nil
  defp trim(s) when is_binary(s), do: String.trim(s)

  defp safe_eval(webview) do
    Page.eval(@extract, webview: webview)
  catch
    :exit, reason -> {:error, {:eval_exit, reason}}
  end
end
