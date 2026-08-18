defmodule BowserBrain.UserContent do
  @moduledoc """
  Owner-keyed registry of injected content (bowser-browser-fc9).

  Two jobs:
  - Mods set scripts/styles under their own key; the engine always receives
    the UNION, so mods can no longer clobber each other's content.
  - A standard preservation script is always included: scroll position and
    non-sensitive input values survive every reload on every page — no mod
    has to hand-roll it. Password/hidden fields and cc/one-time-code
    autocompletes are never touched.

  Re-pushes everything on engine hello, so mods don't need to.
  """
  use GenServer

  alias BowserBrain.Bridge

  # Keyed per origin+path in sessionStorage. Restores retry briefly so pages
  # (or mods!) that rebuild the DOM after load still get their values back.
  @std_preserve """
  (function () {
    var KEY = "bowser-preserve:" + location.host + location.pathname;
    function fields() {
      return Array.prototype.filter.call(
        document.querySelectorAll("input, textarea"),
        function (el) {
          var t = (el.type || "").toLowerCase();
          if (t === "password" || t === "hidden") return false;
          var ac = (el.getAttribute("autocomplete") || "").toLowerCase();
          if (ac.indexOf("cc-") !== -1 || ac.indexOf("one-time") !== -1) return false;
          return !!(el.name || el.id);
        });
    }
    // localStorage (not sessionStorage): survives engine kills and full
    // restarts. The freshness window keeps a restart-from-minutes-ago
    // restoring scroll without haunting next week's visit.
    var MAX_AGE_MS = 6 * 60 * 60 * 1000;
    function save() {
      // Merge-write: never erase a stored value with an empty field (a mod
      // rewriting the DOM mid-tick would otherwise wipe the snapshot).
      var data = null;
      try { data = JSON.parse(localStorage.getItem(KEY) || "null"); } catch (e) {}
      if (!data) data = { y: 0, f: {} };
      if (window.scrollY) data.y = window.scrollY;
      fields().forEach(function (el) {
        if (el.value) data.f[el.name || el.id] = el.value;
      });
      data.at = Date.now();
      try { localStorage.setItem(KEY, JSON.stringify(data)); } catch (e) {}
    }
    function restore() {
      var data = null;
      try { data = JSON.parse(localStorage.getItem(KEY) || "null"); } catch (e) {}
      if (!data) return;
      if (data.at && Date.now() - data.at > MAX_AGE_MS) return;
      fields().forEach(function (el) {
        var v = data.f[el.name || el.id];
        if (v && !el.value) el.value = v;
      });
      if (data.y) window.scrollTo(0, data.y);
    }
    function boot() {
      restore();
      setTimeout(restore, 50);
      setTimeout(restore, 400);
      // Listeners where Servo delivers them...
      document.addEventListener("input", save, true);
      document.addEventListener("keyup", save, true);
      window.addEventListener("scroll", save, { passive: true });
      // ...and a poll as ground truth: Servo doesn't reliably deliver
      // input events to document-level listeners yet.
      setInterval(save, 400);
    }
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
    else boot();
  })();
  """


  # The chrome band is transparent and the page runs under it. A root-level
  # transform shifts ALL content (fixed/sticky headers included — transforms
  # re-anchor them to the page) below the band, while the page background
  # still paints the full canvas under the chrome. 34 = band height.
  @band_offset """
  (function () {
    if (window.top !== window) return;
    var s = document.createElement("style");
    s.id = "bowser-band-offset";
    s.textContent = "html { transform: translateY(34px); }";
    (document.head || document.documentElement).appendChild(s);
  })();
  """

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def put_scripts(owner, scripts, opts \\ []) when is_list(scripts) do
    GenServer.call(__MODULE__, {:put, :scripts, owner, scripts, Keyword.get(opts, :reload, true)})
  end

  def put_styles(owner, styles, opts \\ []) when is_list(styles) do
    GenServer.call(__MODULE__, {:put, :styles, owner, styles, Keyword.get(opts, :reload, true)})
  end

  @impl true
  def init(nil) do
    {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
    {:ok, %{scripts: %{}, styles: %{}}}
  end

  @impl true
  def handle_call({:put, kind, owner, list, reload}, _from, state) do
    bucket =
      if list == [] do
        Map.delete(Map.fetch!(state, kind), owner)
      else
        Map.put(Map.fetch!(state, kind), owner, list)
      end

    state = Map.put(state, kind, bucket)
    push(state, reload)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:browser_event, %{"event" => "hello"}}, state) do
    # Fresh engine: content registered before pages load, no reload needed.
    push(state, false)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp push(state, reload) do
    Bridge.cast_msg(%{
      op: "set_user_content",
      webview: 0,
      scripts: [@std_preserve, @band_offset | flatten(state.scripts)],
      styles: flatten(state.styles),
      reload: reload
    })
  end

  defp flatten(bucket) do
    bucket |> Enum.sort() |> Enum.flat_map(fn {_owner, list} -> list end)
  end
end
