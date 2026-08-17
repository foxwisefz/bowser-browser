# The vision demo (bowser-browser-2w3): completely rewrite a live website.
# On news.ycombinator.com, this mod tears down HN's 90s table layout and
# rebuilds the page as clean story cards — via an ENGINE-injected user
# script, so it applies on every load and survives navigation.
#
# Toggle: the "HN" toolbar button, or `:hn` in the omnibar.
# Edit this file while browsing (colors, layout, anything) — it hot-swaps.
defmodule HnMod do
  use BowserBrain.Mod

  alias BowserBrain.{Chrome, Page}

  @script """
  (function () {
    if (location.hostname !== "news.ycombinator.com") return;

    function esc(s) {
      var d = document.createElement("div");
      d.textContent = s || "";
      return d.innerHTML;
    }

    function rewrite() {
      var rows = Array.prototype.slice.call(document.querySelectorAll("tr.athing"));
      if (!rows.length) return; // comment pages etc. — leave alone

      var cards = rows.map(function (row) {
        var t = row.querySelector(".titleline a");
        var site = row.querySelector(".sitestr");
        var rank = (row.querySelector(".rank") || {}).textContent || "";
        var sub = row.nextElementSibling;
        var score = sub && sub.querySelector(".score");
        var links = sub ? sub.querySelectorAll("a") : [];
        var last = links.length ? links[links.length - 1] : null;
        var comments = last && /comment|discuss/.test(last.textContent) ? last : null;
        return {
          href: t ? t.href : "#",
          title: t ? t.textContent : "untitled",
          site: site ? site.textContent : "",
          rank: rank.replace(".", ""),
          score: score ? score.textContent : "",
          chref: comments ? comments.href : null,
          ctext: comments ? comments.textContent : ""
        };
      });

      var more = document.querySelector("a.morelink");
      document.body.innerHTML =
        '<div id="bowser-hn">' +
        '<header><h1>Hacker News</h1>' +
        '<span class="tag">rewritten live by a Bowser mod</span>' +
        '<input id="bowser-hn-q" type="search" placeholder="Search HN…"></header>' +
        cards.map(function (c) {
          return '<article class="bowser-hn-card">' +
            '<span class="rank">' + esc(c.rank) + '</span>' +
            '<div class="main">' +
            '<a class="title" href="' + esc(c.href) + '">' + esc(c.title) + '</a>' +
            (c.site ? '<span class="site">' + esc(c.site) + '</span>' : '') +
            '<div class="meta">' + esc(c.score) +
            (c.chref
              ? (c.score ? ' · ' : '') + '<a href="' + esc(c.chref) + '">' + esc(c.ctext) + '</a>'
              : '') +
            '</div></div></article>';
        }).join("") +
        (more ? '<a class="more" href="' + esc(more.href) + '">More →</a>' : '') +
        '</div>';

      var q = document.getElementById("bowser-hn-q");
      if (q) {
        try {
          var savedQ = sessionStorage.getItem("bowser-hn-q");
          if (savedQ) q.value = savedQ;
        } catch (e) {}
        q.addEventListener("input", function () {
          try { sessionStorage.setItem("bowser-hn-q", q.value); } catch (e) {}
        });
        q.addEventListener("keydown", function (e) {
          if (e.key === "Enter" && q.value.trim()) {
            location.href = "https://hn.algolia.com/?q=" + encodeURIComponent(q.value.trim());
          }
        });
      }

      // Survive the reloads that toggling/editing this mod causes.
      var y = 0;
      try { y = parseInt(sessionStorage.getItem("bowser-hn-scroll") || "0", 10); } catch (e) {}
      if (y) window.scrollTo(0, y);
      window.addEventListener("scroll", function () {
        try { sessionStorage.setItem("bowser-hn-scroll", String(window.scrollY)); } catch (e) {}
      }, { passive: true });

      var st = document.createElement("style");
      st.textContent =
        "body { margin: 0; background: #0f1115; color: #e8e6e1;" +
        "  font-family: system-ui, sans-serif; }" +
        "#bowser-hn { max-width: 640px; margin: 0 auto; padding: 28px 16px 64px; }" +
        "#bowser-hn header { display: flex; align-items: baseline; gap: 12px;" +
        "  border-bottom: 1px solid #2a2e38; padding-bottom: 14px; margin-bottom: 10px; }" +
        "#bowser-hn h1 { font-size: 22px; margin: 0; }" +
        "#bowser-hn .tag { font-size: 12px; color: #f0873c; }" +
        "#bowser-hn-q { margin-left: auto; background: #1a1e26; color: #e8e6e1;" +
        "  border: 1px solid #2a2e38; border-radius: 6px; padding: 6px 10px;" +
        "  font-size: 13px; width: 180px; }" +
        ".bowser-hn-card { display: flex; gap: 14px; padding: 13px 4px;" +
        "  border-bottom: 1px solid #1c1f27; }" +
        ".bowser-hn-card .rank { color: #565d6b; font-size: 13px; min-width: 22px;" +
        "  text-align: right; padding-top: 3px; }" +
        ".bowser-hn-card .title { color: #e8e6e1; font-size: 16.5px; font-weight: 600;" +
        "  text-decoration: none; line-height: 1.35; }" +
        ".bowser-hn-card .title:hover { color: #f0873c; }" +
        ".bowser-hn-card .site { color: #8a93a3; font-size: 12.5px; margin-left: 8px; }" +
        ".bowser-hn-card .meta { color: #8a93a3; font-size: 12.5px; margin-top: 4px; }" +
        ".bowser-hn-card .meta a { color: #8a93a3; }" +
        "#bowser-hn .more { display: block; padding: 18px 40px; color: #f0873c; }";
      document.head.appendChild(st);
    }

    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", rewrite);
    } else {
      rewrite();
    }
  })();
  """

  # Injected when the rewrite is OFF: no visual changes, but typed search
  # text and scroll survive the round trip through the original page.
  @carrier """
  (function () {
    if (location.hostname !== "news.ycombinator.com") return;
    function hook() {
      var input = document.querySelector('form[action*="algolia"] input[name="q"]') ||
                  document.querySelector('input[name="q"]');
      if (input) {
        try {
          var v = sessionStorage.getItem("bowser-hn-q");
          if (v && !input.value) input.value = v;
        } catch (e) {}
        input.addEventListener("input", function () {
          try { sessionStorage.setItem("bowser-hn-q", input.value); } catch (e) {}
        });
      }
      var y = 0;
      try { y = parseInt(sessionStorage.getItem("bowser-hn-scroll") || "0", 10); } catch (e) {}
      if (y) window.scrollTo(0, y);
      window.addEventListener("scroll", function () {
        try { sessionStorage.setItem("bowser-hn-scroll", String(window.scrollY)); } catch (e) {}
      }, { passive: true });
    }
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", hook);
    else hook();
  })();
  """

  def init_mod(_opts) do
    assert_chrome()
    # Apply immediately when dropped into a live session; harmlessly dropped
    # if the engine isn't connected yet (hello re-asserts).
    Page.set_scripts([@script])
    %{on: true}
  end

  def handle_event(%{"event" => "hello"}, state) do
    assert_chrome()
    Page.set_scripts([current_script(state)], reload: false)
    state
  end

  # Fired by the Loader after a hot swap: re-inject with the new script.
  def handle_event(%{"event" => "mod_reloaded"}, state) do
    Page.set_scripts([current_script(state)])
    state
  end

  def handle_event(%{"event" => "chrome_click", "id" => "hn"}, state), do: toggle(state)
  def handle_event(%{"event" => "omnibar_command", "text" => "hn"}, state), do: toggle(state)
  def handle_event(_event, state), do: state

  defp assert_chrome, do: Chrome.add_button("hn", "HN", symbol: "newspaper")

  defp toggle(%{on: false} = state) do
    Page.set_scripts([@script])
    %{state | on: true}
  end

  defp toggle(%{on: true} = state) do
    Page.set_scripts([@carrier])
    %{state | on: false}
  end

  defp current_script(%{on: true}), do: @script
  defp current_script(%{on: false}), do: @carrier
end
