defmodule FollowFlywheel do
  @moduledoc """
  Follow Flywheel — brain half (pairs with sites/x.com/follow-flywheel.js).

  Engage with a post (like / bookmark / retweet / reply) whose author has
  fewer than 5k followers -> auto-follow them. If they follow back within
  4 days they are kept. If not they enter the unfollow queue, visible in
  the "Follow Flywheel" panel for 24h so interesting accounts can be
  spared; then they are auto-unfollowed. Re-engaging with a queued
  account spares it automatically. All history lives in the Store.
  """
  # Handoff: state contains only the webview id. History and sweep timestamps
  # live in Store; there are no BEAM timers/tasks/ports. Page fetches stay in
  # WebKit and report through the buffered event bridge. Restoring skips
  # init_mod/hello, so it must not start another sweep or repeat an action.
  use BowserBrain.Mod, host: "x.com", handoff: true

  alias BowserBrain.{Store, Page, Budget, Surface}
  import BowserBrain.View

  @max_followers 5_000
  @grace_s 4 * 86_400        # wait this long for a follow-back
  @spare_window_s 86_400     # time in the queue before auto-unfollow
  @sweep_every_s 6 * 3_600   # how often to run checks

  def init_mod(_opts) do
    show_panel()
    %{wv: nil}
  end

  # ---- engagement detected by the page hook ------------------------------
  def handle_event(%{"event" => "page", "webview" => wv,
                     "payload" => %{"kind" => "ff_engaged", "how" => how, "user" => u}}, state) do
    state = %{state | wv: wv}
    on_engaged(u, how, state)
    maybe_sweep(state)
  end

  # ---- API results coming back from the page -----------------------------
  def handle_event(%{"event" => "page", "payload" => %{"kind" => "ff_api"} = p}, state) do
    on_api(p)
    state
  end

  # ---- panel buttons ------------------------------------------------------
  def handle_event(%{"event" => "surface", "surface" => "ff", "id" => id} = ev, state) do
    uid = clean_id(ev["value"])

    case id do
      "spare" when uid != "" ->
        set_status(uid, "spared", %{"spared_at" => now()})
        note("spared @" <> handle_of(uid))

      "unfoll" when uid != "" ->
        do_unfollow(uid, state)

      "sweep" ->
        Store.put(__MODULE__, "last_sweep", 0)

      _ ->
        :ok
    end

    show_panel()
    maybe_sweep(state)
  end

  # ---- the Store was written from outside (seeding/cleanup/owner edit) ----
  def handle_event(%{"event" => "store_changed"}, state) do
    show_panel()
    state
  end

  # ---- engine restart: re-assert shell-side state -------------------------
  def handle_event(%{"event" => "hello"} = ev, state) do
    wv =
      ev
      |> Map.get("tabs", [])
      |> Enum.find_value(fn t ->
        if is_binary(t["url"]) and String.contains?(t["url"], "x.com"), do: t["id"]
      end)

    show_panel()
    %{state | wv: wv || state.wv}
  end

  # Sweep only when a page is fully loaded — the hook must be alive to
  # receive our __ffApi calls (a sweep mid-reload is silently lost).
  def handle_event(%{"event" => "load_status", "status" => 2, "webview" => wv}, state) do
    maybe_sweep(%{state | wv: wv})
  end

  def handle_event(_ev, state), do: state

  # ---- engagement logic ---------------------------------------------------
  defp on_engaged(u, how, state) do
    id = clean_id(u["id"])
    rec = follows()[id]

    cond do
      id == "" ->
        :ok

      rec != nil ->
        case rec["status"] do
          "due" ->
            set_status(id, "spared", %{"spared_at" => now(), "note" => "re-engaged"})
            note("spared @" <> handle_of(id) <> " (you engaged again)")

          "pending" ->
            update_rec(id, fn r -> Map.update(r, "engagements", 2, &(&1 + 1)) end)

          _ ->
            :ok
        end

      u["protected"] ->
        :ok

      u["following"] ->
        :ok

      not is_integer(u["followers"]) or u["followers"] >= @max_followers ->
        :ok

      true ->
        start_follow(id, u, how, state)
    end

    show_panel()
  end

  defp start_follow(id, u, how, state) do
    case Budget.take(__MODULE__, "x.com") do
      {:error, :exhausted} ->
        Store.put(__MODULE__, "budget_note",
          "Daily action budget exhausted — @" <> to_string(u["handle"] || id) <> " not followed")

      _ ->
        rec = %{
          "handle" => u["handle"],
          "followers" => u["followers"],
          "how" => how,
          "followed_at" => now(),
          "status" => if(u["followed_by"], do: "kept", else: "pending"),
          "confirmed" => false,
          "engagements" => 1
        }

        put_rec(id, rec)
        Page.eval("window.__ffApi('follow','#{id}','follow:#{id}')", webview: state.wv || 0)
    end
  end

  # ---- API responses ------------------------------------------------------
  defp on_api(%{"op" => "follow", "tag" => "follow:" <> id} = p) do
    if p["status"] == 200 do
      update_rec(id, &Map.put(&1, "confirmed", true))
      note("followed @" <> handle_of(id))
    else
      err = p["error"] || (is_map(p["data"]) && p["data"]["error"]) || p["status"]
      note("follow failed (#{inspect(err)})")
      Store.update(__MODULE__, "follows", %{}, &Map.delete(&1, id))
    end

    show_panel()
  end

  defp on_api(%{"op" => "lookup", "tag" => "check", "data" => rows}) when is_list(rows) do
    Enum.each(rows, fn row ->
      id = clean_id(row["id"])
      conns = row["connections"] || []

      cond do
        id == "" -> :ok
        "followed_by" in conns -> set_status(id, "kept", %{"kept_at" => now()})
        "following" not in conns -> set_status(id, "external", %{"note" => "not following anymore"})
        true -> set_status(id, "due", %{"due_at" => now()})
      end
    end)

    show_panel()
  end

  defp on_api(%{"op" => "unfollow", "tag" => "unfollow:" <> id} = p) do
    if p["status"] == 200 do
      set_status(id, "unfollowed", %{"unfollowed_at" => now()})
      note("unfollowed @" <> handle_of(id))
    else
      set_status(id, "due", %{"note" => "unfollow failed, will retry"})
    end

    show_panel()
  end

  defp on_api(_), do: :ok

  # ---- periodic sweep -----------------------------------------------------
  defp maybe_sweep(state) do
    nw = now()

    if state.wv != nil and nw - Store.get(__MODULE__, "last_sweep", 0) >= @sweep_every_s do
      sweep(state, nw)
    end

    state
  end

  defp sweep(state, nw) do
    Store.put(__MODULE__, "last_sweep", nw)
    fl = follows()

    # pending past the grace period -> one batched follow-back lookup
    check_ids =
      fl
      |> Enum.filter(fn {_id, r} ->
        r["status"] == "pending" and nw - (r["followed_at"] || nw) >= @grace_s
      end)
      |> Enum.map(fn {id, _} -> id end)
      |> Enum.take(90)

    if check_ids != [] do
      Page.eval("window.__ffApi('lookup','#{Enum.join(check_ids, ",")}','check')",
        webview: state.wv)
    end

    # unfollow calls that never came back -> requeue
    fl
    |> Enum.filter(fn {_id, r} ->
      r["status"] == "unfollowing" and nw - (r["acted_at"] || 0) > 3_600
    end)
    |> Enum.each(fn {id, _} -> set_status(id, "due", %{}) end)

    # queued longer than the spare window -> dump
    fl
    |> Enum.filter(fn {_id, r} ->
      r["status"] == "due" and nw - (r["due_at"] || nw) >= @spare_window_s
    end)
    |> Enum.each(fn {id, _} -> do_unfollow(id, state) end)
  end

  defp do_unfollow(id, state) when is_binary(id) and id != "" do
    case Budget.take(__MODULE__, "x.com") do
      {:error, :exhausted} ->
        Store.put(__MODULE__, "budget_note", "Daily action budget exhausted — unfollow queue paused")

      _ ->
        set_status(id, "unfollowing", %{"acted_at" => now()})
        Page.eval("window.__ffApi('unfollow','#{id}','unfollow:#{id}')", webview: state.wv || 0)
    end
  end

  defp do_unfollow(_, _), do: :ok

  # ---- panel --------------------------------------------------------------
  defp show_panel do
    fl = follows()
    nw = now()
    by = Enum.group_by(fl, fn {_id, r} -> r["status"] end)
    n = fn s -> length(Map.get(by, s, [])) end

    due = by |> Map.get("due", []) |> Enum.sort_by(fn {_id, r} -> r["due_at"] || 0 end)

    pending =
      by |> Map.get("pending", []) |> Enum.sort_by(fn {_id, r} -> -(r["followed_at"] || 0) end)

    due_rows =
      due
      |> Enum.take(12)
      |> Enum.map(fn {id, r} ->
        hstack([
          text("@" <> to_string(r["handle"] || id)),
          text(days_ago(r["followed_at"], nw), style: :caption),
          button("Spare", event: "spare", payload: id),
          button("Unfollow", event: "unfoll", payload: id)
        ])
      end)

    pending_rows =
      pending
      |> Enum.take(8)
      |> Enum.map(fn {id, r} ->
        text(
          "@" <>
            to_string(r["handle"] || id) <>
            " · " <> days_ago(r["followed_at"], nw) <> " · " <> fmt_k(r["followers"]),
          style: :caption
        )
      end)

    log =
      Store.get(__MODULE__, "log", [])
      |> Enum.take(4)
      |> Enum.map(&text(&1["msg"], style: :caption))

    bn = Store.get(__MODULE__, "budget_note", nil)

    view =
      vstack(
        [
          text("Follow Flywheel", style: :title),
          text(
            "#{n.("pending")} waiting · #{n.("kept")} follow back · " <>
              "#{n.("unfollowed")} dumped · #{n.("spared")} spared",
            style: :caption
          ),
          divider(),
          text("Unfollow queue (#{length(due)}) — auto-dump after 24h", style: :caption)
        ] ++
          if(due_rows == [], do: [text("empty", style: :caption)], else: due_rows) ++
          [divider(), text("Waiting for follow-back (4 days)", style: :caption)] ++
          if(pending_rows == [], do: [text("none", style: :caption)], else: pending_rows) ++
          [divider()] ++
          if(bn, do: [text(bn, style: :caption)], else: []) ++
          log ++
          [button("Check follow-backs now", event: "sweep")]
      )

    Surface.show("ff", view, title: "Follow Flywheel", anchor: :right_of_main)
  end

  # ---- helpers ------------------------------------------------------------
  defp now, do: System.system_time(:second)

  defp clean_id(v), do: String.replace(to_string(v || ""), ~r/\D/, "")

  defp follows, do: Store.get(__MODULE__, "follows", %{})

  defp handle_of(id) do
    case follows()[id] do
      %{"handle" => h} when is_binary(h) and h != "" -> h
      _ -> id
    end
  end

  defp put_rec(id, rec), do: Store.update(__MODULE__, "follows", %{}, &Map.put(&1, id, rec))

  defp update_rec(id, f) do
    Store.update(__MODULE__, "follows", %{}, fn m ->
      case m[id] do
        nil -> m
        r -> Map.put(m, id, f.(r))
      end
    end)
  end

  defp set_status(id, status, extra) do
    update_rec(id, fn r -> r |> Map.put("status", status) |> Map.merge(extra) end)
  end

  defp note(msg) do
    Store.update(__MODULE__, "log", [], fn l ->
      Enum.take([%{"at" => now(), "msg" => msg} | l], 10)
    end)
  end

  defp days_ago(nil, _), do: ""

  defp days_ago(t, nw) do
    d = div(max(nw - t, 0), 86_400)
    if d == 0, do: "today", else: "#{d}d ago"
  end

  defp fmt_k(nil), do: "?"
  defp fmt_k(nc) when nc >= 1000, do: "#{Float.round(nc / 1000, 1)}k followers"
  defp fmt_k(nc), do: "#{nc} followers"
end
