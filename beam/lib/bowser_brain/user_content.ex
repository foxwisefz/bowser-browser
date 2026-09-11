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
    }
    // Scroll restore is a CAMPAIGN, not a shot: virtualized/slow pages
    // (x.com, YT Music) are not tall enough at load, scrollTo clamps to ~0
    // and the position was lost — and the save loop then overwrote the
    // stored y with the clamped value (bowser-browser-l8r). And on
    // infinite-scroll sites waiting is not enough: content only grows when
    // something presses toward the bottom, so the campaign WALKS the loader
    // back to depth (bowser-browser-uuy) — DOM save/reinject was rejected:
    // serialized HTML without its JS heap is a corpse. The target lives in
    // this closure so mid-restore saves cannot corrupt it; a stall (no
    // growth for 4s) or the owner scrolling ends the campaign.
    function restoreScroll() {
      var data = null;
      try { data = JSON.parse(localStorage.getItem(KEY) || "null"); } catch (e) {}
      if (!data || !data.y) return;
      if (data.at && Date.now() - data.at > MAX_AGE_MS) return;
      var target = data.y;
      var deadline = Date.now() + 25000;
      var cancelled = false;
      var lastH = 0, lastGrowthAt = Date.now();
      function cancel() { cancelled = true; }
      window.addEventListener("wheel", cancel, { once: true, passive: true });
      window.addEventListener("keydown", cancel, { once: true });
      (function attempt() {
        if (cancelled || Date.now() > deadline) return;
        // Semantic media recovery owns the scroll anchor for a saved X tweet.
        if (window.__bowserMediaRestoring) return;
        var se = document.scrollingElement || document.documentElement;
        if (se.scrollHeight !== lastH) { lastH = se.scrollHeight; lastGrowthAt = Date.now(); }
        var maxY = se.scrollHeight - window.innerHeight;
        if (maxY >= target - 4) {
          window.scrollTo(0, target);
          if (Math.abs(window.scrollY - target) < 8) return; // landed
        } else {
          // Not tall enough yet: press against the bottom so the infinite
          // loader fetches — but a page that stops growing was never going
          // to reach the target (finite page, feed end): stay where the
          // content ran out rather than pinning the bottom forever.
          if (Date.now() - lastGrowthAt > 4000) return;
          window.scrollTo(0, Math.max(0, maxY));
        }
        setTimeout(attempt, 250);
      })();
    }
    function boot() {
      restore();
      restoreScroll();
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

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def put_scripts(owner, scripts, opts \\ []) when is_list(scripts) do
    GenServer.call(__MODULE__, {:put, :scripts, {owner, Keyword.get(opts, :profile, BowserBrain.ModScope.current())}, scripts, Keyword.get(opts, :reload, true)})
  end

  def put_styles(owner, styles, opts \\ []) when is_list(styles) do
    GenServer.call(__MODULE__, {:put, :styles, {owner, Keyword.get(opts, :profile, BowserBrain.ModScope.current())}, styles, Keyword.get(opts, :reload, true)})
  end

  @doc """
  Synchronously enqueue the full content push ahead of the caller's next
  casts. Session calls this BEFORE restoring (bowser-browser-6eu): both
  react to the same hello, and without this the restore navigations could
  reach the engine first — the restored page's first paint had no styles.
  """
  def push_now do
    GenServer.call(__MODULE__, :push_now)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(nil) do
    {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
    {:ok, %{scripts: %{}, styles: %{}}}
  end

  @impl true
  def handle_call(:push_now, _from, state) do
    push(state, false)
    {:reply, :ok, state}
  end

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
    profiles = for bucket <- [state.scripts, state.styles], {{_, profile}, _} <- bucket, do: profile
    profiles = Enum.uniq([nil | profiles] ++ Process.get(:published_profiles, []))
    Process.put(:published_profiles, profiles)
    for profile <- profiles do
      Bridge.cast_msg(%{op: "set_user_content", webview: 0, profile: profile,
        scripts: (if is_nil(profile), do: [@std_preserve], else: []) ++ flatten(state.scripts, profile),
        styles: flatten(state.styles, profile), reload: reload})
    end
  end

  defp flatten(bucket, profile) do
    bucket |> Enum.sort() |> Enum.flat_map(fn
      {{_owner, ^profile}, list} -> list
      {{_, _}, _} -> []
      {_owner, list} -> if is_nil(profile), do: list, else: []
    end)
  end
end
