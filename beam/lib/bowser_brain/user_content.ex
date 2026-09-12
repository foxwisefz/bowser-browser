defmodule BowserBrain.UserContent do
  @moduledoc """
  Owner-keyed registry of injected content (bowser-browser-fc9).

  Two jobs:
  - Mods set scripts/styles under their own key; the engine always receives
    the UNION, so mods can no longer clobber each other's content.
  - A standard preservation script restores scroll position across reloads.
    It never reads, stores, or restores form field values.

  Re-pushes everything on engine hello, so mods don't need to.
  """
  use GenServer

  alias BowserBrain.Bridge

  # Scroll coordinates only, keyed per origin+path. Retries accommodate
  # virtualized and slow-loading pages without capturing their contents.
  @std_preserve """
  (function () {
    var KEY = "bowser-scroll:" + location.host + location.pathname;
    // Delete previous field snapshots without reading or replaying them.
    // Visit each storage separately: either may be unavailable on a page.
    function discardFields(storage) {
      for (var i = storage.length - 1; i >= 0; i--) {
        var key = storage.key(i);
        if (key && key.indexOf("bowser-preserve:") === 0) storage.removeItem(key);
      }
    }
    try { discardFields(localStorage); } catch (e) {}
    try { discardFields(sessionStorage); } catch (e) {}
    var MAX_AGE_MS = 6 * 60 * 60 * 1000;
    function save() {
      var data = { y: Math.max(0, window.scrollY), at: Date.now() };
      try { localStorage.setItem(KEY, JSON.stringify(data)); } catch (e) {}
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
      if (!data || !Number.isFinite(data.y) || data.y <= 0) return;
      if (!Number.isFinite(data.at) || Date.now() - data.at > MAX_AGE_MS) return;
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
      restoreScroll();
      window.addEventListener("scroll", save, { passive: true });
      window.addEventListener("pagehide", save);
    }
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
    else boot();
  })();
  """

  @doc false
  def preservation_script, do: @std_preserve

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def put_scripts(owner, scripts, opts \\ []) when is_list(scripts) do
    opts = Keyword.put(opts, :host, BowserBrain.ScriptPolicy.owner_host(owner))
    scripts = Enum.map(scripts, &BowserBrain.ScriptPolicy.normalize(&1, opts))
    GenServer.call(__MODULE__, {:put, :scripts, {owner, Keyword.get(opts, :profile, BowserBrain.ModScope.current())}, scripts, Keyword.get(opts, :reload, true)})
  end

  def put_styles(owner, styles, opts \\ []) when is_list(styles) do
    unless Enum.all?(styles, &is_binary/1), do: raise(ArgumentError, "styles must be strings")
    profile = Keyword.get(opts, :profile, BowserBrain.ModScope.current())
    GenServer.call(__MODULE__, {:put_styles, {owner, profile}, styles,
      BowserBrain.ScriptPolicy.owner_host(owner), Keyword.get(opts, :reload, true)})
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

  def handle_call({:put_styles, {owner, profile} = key, styles, host, reload}, _from, state) do
    script_key = {{:scoped_styles, owner}, profile}
    # Always clear both representations: a declaration may change host or
    # become global on reload. Styles never share their owner's JS bucket.
    state = %{state | styles: Map.delete(state.styles, key), scripts: Map.delete(state.scripts, script_key)}
    state = cond do
      styles == [] -> state
      is_nil(host) -> %{state | styles: Map.put(state.styles, key, styles)}
      true ->
        scripts = Enum.map(styles, fn css ->
          %{host: host, world: "isolated", source: """
          (function () {
            var style = document.createElement("style");
            style.textContent = #{JSON.encode!(css)};
            (document.head || document.documentElement).appendChild(style);
          })();
          """}
        end)
        %{state | scripts: Map.put(state.scripts, script_key, scripts)}
    end
    push(state, reload)
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
        scripts: (if is_nil(profile), do: [%{source: @std_preserve, world: "page"}], else: []) ++ flatten(state.scripts, profile),
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
