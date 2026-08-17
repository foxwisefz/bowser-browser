# The GIMP-window ask (bowser-browser-2un): Twitter's navbar "popped out"
# into a native floating palette. Not a DOM transplant (no engine can do
# that) — a live semantic mirror: an injected observer streams the navbar's
# items and badge counts to this mod via window.bowser.emit(); the palette
# renders them natively; clicks relay back into the real page.
defmodule TwitterNavMod do
  use BowserBrain.Mod
  import BowserBrain.View
  alias BowserBrain.{Page, Surface}

  @script """
  (function () {
    if (!/(^|\\.)x\\.com$|(^|\\.)twitter\\.com$/.test(location.hostname)) return;

    function snapshot() {
      var nav = document.querySelector('header nav[role="navigation"]');
      if (!nav) return null;
      return Array.prototype.map.call(
        nav.querySelectorAll('a[role="link"]'),
        function (a) {
          var href = a.getAttribute("href") || "";
          return {
            label: (a.getAttribute("aria-label") || a.textContent || "").trim(),
            href: href,
            active: href === location.pathname
          };
        }
      ).filter(function (item) { return item.label && item.href; });
    }

    var last = "";
    var pending = null;
    function push() {
      if (pending) return;
      pending = setTimeout(function () {
        pending = null;
        var items = snapshot();
        if (!items) return;
        var s = JSON.stringify(items);
        if (s === last) return;
        last = s;
        window.bowser && window.bowser.emit({ kind: "twitter_nav", items: items });
      }, 250);
    }

    function boot() {
      push();
      new MutationObserver(push).observe(document.body, {
        subtree: true, childList: true,
        attributes: true, attributeFilter: ["aria-label"]
      });
      setInterval(push, 3000); // SPA safety net
    }

    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
    else boot();
  })();
  """

  def init_mod(_opts) do
    Page.set_scripts([@script])
    %{items: [], hidden: false, active: 0, path: nil}
  end

  def handle_event(%{"event" => "hello"}, state) do
    Page.set_scripts([@script], reload: false)
    state
  end

  def handle_event(%{"event" => "mod_reloaded"}, state) do
    Page.set_scripts([@script])
    state
  end

  def handle_event(%{"event" => "tab_activated", "webview" => wv}, state) do
    %{state | active: wv}
  end

  # Track the current path brain-side so the active highlight works even
  # independently of the injected script's own active flag.
  def handle_event(%{"event" => "url_changed", "url" => url}, state) do
    case URI.parse(url) do
      %URI{host: host, path: path}
      when is_binary(host) and (host == "x.com" or host == "twitter.com") ->
        if state.items != [], do: render(%{state | path: path || "/"}), else: %{state | path: path || "/"}

      _ ->
        state
    end
  end

  def handle_event(
        %{"event" => "page", "payload" => %{"kind" => "twitter_nav", "items" => items}},
        state
      ) do
    render(%{state | items: items})
  end

  def handle_event(%{"event" => "surface", "surface" => "twitter_nav", "id" => id} = event, state) do
    case id do
      "go" ->
        Page.eval(click_js(event["value"]), webview: state.active)
        state

      "toggle_orig" ->
        Page.eval(toggle_hide_js(), webview: state.active)
        render(%{state | hidden: !state.hidden})

      _ ->
        state
    end
  end

  def handle_event(_event, state), do: state

  defp render(state) do
    rows =
      for %{"label" => label, "href" => href} = item <- state.items do
        button(String.slice(label, 0, 30),
          event: :go,
          payload: href,
          active: item["active"] == true or (state.path != nil and href == state.path)
        )
      end

    hide_label = if state.hidden, do: "Show original nav", else: "Hide original nav"

    Surface.show(
      :twitter_nav,
      vstack(
        [text("Twitter", style: :title)] ++
          rows ++
          [divider(), button(hide_label, event: :toggle_orig, symbol: "eye")]
      ),
      title: "Nav",
      anchor: :left_of_main,
      width: 210
    )

    state
  end

  # Click the real nav link (SPA-friendly); fall back to navigation.
  defp click_js(href) do
    """
    (function () {
      var href = #{JSON.encode!(href)};
      var links = document.querySelectorAll('header nav[role="navigation"] a[role="link"]');
      for (var i = 0; i < links.length; i++) {
        if (links[i].getAttribute("href") === href) { links[i].click(); return true; }
      }
      location.href = href;
      return false;
    })()
    """
  end

  defp toggle_hide_js do
    """
    (function () {
      var s = document.getElementById("bowser-twitter-hide");
      if (s) { s.remove(); return false; }
      s = document.createElement("style");
      s.id = "bowser-twitter-hide";
      s.textContent = 'header[role="banner"] { display: none !important; }';
      document.head.appendChild(s);
      return true;
    })()
    """
  end
end
