defmodule BowserBrain.Budget do
  @moduledoc """
  Per-mod, per-host daily cap on automated site actions (bowser-browser-5ba).

  Follow/unfollow churn gets accounts limited even when the owner is present,
  and a generated mod should not be trusted to self-limit. Convention the
  platform records and ModSmith enforces in every mod it writes: before any
  action (follow, unfollow, like, post, DM) call `take/2`; stop on
  `{:error, :exhausted}`. Counts live in the Store under scope "budget",
  keyed mod|host|day, so they survive restarts. The owner tunes the cap
  with `:set action_budget N`.
  """
  alias BowserBrain.{Settings, Store}

  @default 30
  @setting "action_budget"
  @scope "budget"

  def declare_setting do
    Settings.declare(@setting,
      about: "Max automated site actions (follow, like, post…) one mod may take per host per day (default #{@default})"
    )
  end

  @doc "Today's cap: the owner's `action_budget` setting, else #{@default}."
  def limit, do: parse_limit(Settings.get(@setting))

  @doc "A positive integer from a raw setting value; anything else is the default. Public for tests."
  def parse_limit(n) when is_integer(n) and n > 0, do: n

  def parse_limit(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 -> n
      _ -> @default
    end
  end

  def parse_limit(_), do: @default

  @doc """
  Spend one action for this mod on this host today. `:ok`, or
  `{:error, :exhausted}` once today's cap is reached (nothing is counted then).
  opts: `date:` and `limit:` for tests.
  """
  def take(mod, host, opts \\ []) do
    key = key(mod, host, opts)
    limit = Keyword.get(opts, :limit, limit())

    if Store.get(@scope, key, 0) >= limit do
      {:error, :exhausted}
    else
      {:ok, _} = Store.update(@scope, key, 0, &(&1 + 1))
      :ok
    end
  end

  @doc "Actions already taken today for this mod on this host."
  def used(mod, host, opts \\ []), do: Store.get(@scope, key(mod, host, opts), 0)

  def remaining(mod, host, opts \\ []) do
    max(Keyword.get(opts, :limit, limit()) - used(mod, host, opts), 0)
  end

  defp key(mod, host, opts) do
    day = opts |> Keyword.get(:date, Date.utc_today()) |> Date.to_iso8601()
    "#{Store.scope(mod)}|#{host}|#{day}"
  end
end
