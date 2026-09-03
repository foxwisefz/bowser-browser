defmodule BowserBrain.Profiles do
  @moduledoc """
  Browser profiles: several "yous" in one Bowser. A profile is its own
  website data store in the engine (cookies, logins, storage), a name, a
  tint for its windows' title bars and an icon. Every window belongs to
  exactly one profile; tabs never cross (that would be a cookie leak) —
  switching to a tab in another profile brings that window forward.

  This module owns the list — ~/.bowser/profiles.json, which the shell reads
  at launch and is told about on every change — and the `:profile` /
  `:profiles` commands. The default profile is the pre-profiles Bowser: the
  engine's default data store, so existing logins stay where they are.
  """
  use GenServer
  require Logger
  import BowserBrain.View
  alias BowserBrain.{Bridge, Chrome, Surface}

  @default %{"id" => "default", "name" => "Personal", "tint" => nil, "icon" => nil, "uuid" => nil}
  @named %{
    "red" => "#e5484d", "orange" => "#f76b15", "yellow" => "#f5d90a", "green" => "#30a46c",
    "teal" => "#12a594", "blue" => "#3e63dd", "purple" => "#8e4ec6", "pink" => "#d6409f",
    "gray" => "#8b8d98", "grey" => "#8b8d98"
  }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def path do
    Application.get_env(:bowser_brain, :profiles_path, Path.join(System.user_home!(), ".bowser/profiles.json"))
  end

  @doc "Every profile, the default first. Never empty."
  def list do
    with {:ok, raw} <- File.read(path()),
         {:ok, decoded} when is_list(decoded) <- JSON.decode(raw) do
      normalize(decoded)
    else
      _ -> [@default]
    end
  end

  def get(id), do: Enum.find(list(), &(&1["id"] == id))

  @doc "Lookup by name (case-insensitive) or id."
  def by_name(name) when is_binary(name) do
    n = name |> String.trim() |> String.downcase()
    Enum.find(list(), &(String.downcase(&1["name"]) == n or &1["id"] == n))
  end

  @doc "Create a profile: `{:ok, profile}` or `{:error, why}`. opts: tint:, icon:."
  def create(name, opts \\ []) do
    name = String.trim(name || "")

    cond do
      name == "" -> {:error, "a profile needs a name"}
      by_name(name) -> {:error, "profile “#{name}” already exists"}
      true ->
        profile = %{
          "id" => unique_id(slug(name), list()),
          "name" => name,
          "tint" => normalize_tint(opts[:tint]),
          "icon" => present(opts[:icon]),
          "uuid" => uuid4()
        }

        save(list() ++ [profile])
        {:ok, profile}
    end
  end

  def update(id, attrs) when is_map(attrs) do
    case get(id) do
      nil -> {:error, "no profile #{id}"}
      p ->
        p =
          Enum.reduce(attrs, p, fn
            {"tint", v}, acc -> Map.put(acc, "tint", normalize_tint(v))
            {"icon", v}, acc -> Map.put(acc, "icon", present(v))
            {"name", v}, acc when is_binary(v) and v != "" -> Map.put(acc, "name", String.trim(v))
            _, acc -> acc
          end)

        save(Enum.map(list(), &if(&1["id"] == id, do: p, else: &1)))
        {:ok, p}
    end
  end

  def delete("default"), do: {:error, "the default profile stays"}

  def delete(id) do
    if get(id), do: save(Enum.reject(list(), &(&1["id"] == id))), else: :ok
    :ok
  end

  # -- pure helpers (public for tests) ----------------------------------------

  @doc "\"tint|work\" -> {\"tint\", \"work\"}; nil for anything else."
  def edit_event(id) when is_binary(id) do
    case String.split(id, "|", parts: 2) do
      [field, pid] when field in ["name", "icon", "tint"] and pid != "" -> {field, pid}
      _ -> nil
    end
  end

  def edit_event(_), do: nil

  @doc """
  Change one attribute from the Settings editor, validated: an empty name
  or a duplicate name is refused; an unknown color is refused rather than
  silently clearing the tint; an empty icon/tint clears it.
  """
  def edit(id, field, value) when field in ["name", "icon", "tint"] do
    value = value |> to_string() |> String.trim()
    existing = by_name(value)

    cond do
      get(id) == nil -> {:error, "no profile #{id}"}
      field == "name" and value == "" -> {:error, "a profile needs a name"}
      field == "name" and existing != nil and existing["id"] != id -> {:error, "profile “#{value}” already exists"}
      field == "tint" and value != "" and normalize_tint(value) == nil -> {:error, "unknown color “#{value}” — blue/red/green/… or #rrggbb"}
      true -> update(id, %{field => value})
    end
  end

  @doc "An id from a name: lowercase letters/digits/dashes, never empty."
  def slug(name) do
    case name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, "-") |> String.trim("-") do
      "" -> "profile"
      s -> s
    end
  end

  @doc "#rgb / #rrggbb (any case) or a known color name -> #rrggbb lowercase; anything else nil."
  def normalize_tint(nil), do: nil

  def normalize_tint(t) when is_binary(t) do
    t = String.trim(t)

    cond do
      Regex.match?(~r/^#[0-9a-fA-F]{6}$/, t) ->
        String.downcase(t)

      Regex.match?(~r/^#[0-9a-fA-F]{3}$/, t) ->
        "#" <> (t |> String.slice(1..3) |> String.graphemes() |> Enum.map_join(&(&1 <> &1)) |> String.downcase())

      true ->
        @named[String.downcase(t)]
    end
  end

  def normalize_tint(_), do: nil

  @doc """
  `:profile new` arguments -> `{name, tint, icon}`: a #hex or color-name
  token is the tint, a single non-word grapheme (emoji) is the icon, the
  rest is the name. `"work blue 🧪"` -> `{"work", "#3e63dd", "🧪"}`.
  """
  def parse_new(rest) do
    {tint, icon, words} =
      rest
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reduce({nil, nil, []}, fn tok, {tint, icon, words} ->
        cond do
          is_nil(tint) and normalize_tint(tok) != nil -> {normalize_tint(tok), icon, words}
          is_nil(icon) and String.length(tok) == 1 and not Regex.match?(~r/^[\w#]$/u, tok) -> {tint, tok, words}
          true -> {tint, icon, words ++ [tok]}
        end
      end)

    {Enum.join(words, " "), tint, icon}
  end

  # -- server: commands + panel ----------------------------------------------

  @impl true
  def init(nil) do
    {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
    {:ok, %{status: nil}}
  end

  @impl true
  def handle_info({:browser_event, %{"event" => "hello"}}, state) do
    Chrome.register_command("profile", "Window in a profile — :profile work · :profile new work blue 🧪 · :profile delete work")
    Chrome.register_command("profiles", "Profiles — Settings window section")
    {:noreply, render(state)}
  end

  def handle_info({:browser_event, %{"event" => "settings_opened"}}, state), do: {:noreply, render(state)}

  def handle_info({:browser_event, %{"event" => "omnibar_command", "text" => "profile new " <> rest}}, state) do
    {:noreply, create_and_open(rest, state)}
  end

  def handle_info({:browser_event, %{"event" => "omnibar_command", "text" => "profile delete " <> name}}, state) do
    case by_name(name) do
      nil -> {:noreply, render(%{state | status: "No profile “#{String.trim(name)}”"})}
      %{"id" => "default"} -> {:noreply, render(%{state | status: "The default profile stays"})}
      p ->
        :ok = delete(p["id"])
        # Its windows stay open until closed; its data store stays on disk
        # (WebKit's identified store) until a future purge command.
        {:noreply, render(%{state | status: "Deleted #{label(p)} — close its windows; logins for it remain on disk"})}
    end
  end

  def handle_info({:browser_event, %{"event" => "omnibar_command", "text" => "profile " <> name}}, state) do
    case by_name(name) do
      nil -> {:noreply, render(%{state | status: "No profile “#{String.trim(name)}” — :profile new #{String.trim(name)}"})}
      p -> Chrome.open_window(p["id"]); {:noreply, state}
    end
  end

  def handle_info({:browser_event, %{"event" => "omnibar_command", "text" => "profiles"}}, state) do
    {:noreply, render(state, true)}
  end

  def handle_info({:browser_event, %{"event" => "surface", "surface" => "profiles", "id" => "open", "value" => id}}, state) do
    Chrome.open_window(to_string(id))
    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "surface", "surface" => "profiles", "id" => "new", "value" => text}}, state) do
    {:noreply, create_and_open(to_string(text), state)}
  end

  def handle_info({:browser_event, %{"event" => "surface", "surface" => "profiles", "id" => "delete", "value" => id}}, state) do
    status =
      case delete(to_string(id)) do
        :ok -> "Deleted — close its windows; its logins stay on disk"
        {:error, why} -> why
      end

    {:noreply, render(%{state | status: status})}
  end

  # Inline edits: textfield ids are "name|<id>", "icon|<id>", "tint|<id>".
  def handle_info({:browser_event, %{"event" => "surface", "surface" => "profiles", "id" => field_id, "value" => value}}, state) do
    case edit_event(field_id) do
      {field, id} ->
        status =
          case edit(id, field, value) do
            {:ok, p} -> "Saved #{label(p)}"
            {:error, why} -> why
          end

        {:noreply, render(%{state | status: status})}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp create_and_open(rest, state) do
    {name, tint, icon} = parse_new(rest)

    case create(name, tint: tint, icon: icon) do
      {:ok, p} ->
        Chrome.open_window(p["id"])
        render(%{state | status: "Created #{label(p)}"})

      {:error, why} ->
        render(%{state | status: why})
    end
  end

  defp render(state, activate \\ false) do
    rows =
      Enum.flat_map(list(), fn p ->
        id = p["id"]
        head = label(p) <> if(p["tint"], do: " · " <> p["tint"], else: "") <> if(id == "default", do: "  (default)", else: "")

        [
          text(head, style: :title),
          hstack([
            textfield("name|" <> id, value: p["name"], placeholder: "name ⏎"),
            textfield("icon|" <> id, value: p["icon"] || "", placeholder: "icon (emoji) ⏎"),
            textfield("tint|" <> id, value: p["tint"] || "", placeholder: "tint: blue or #3e63dd ⏎")
          ]),
          hstack(
            [button("Open window", event: "open", payload: id, compact: true)] ++
              if(id == "default", do: [], else: [button("Delete", event: "delete", payload: id, compact: true)])
          ),
          divider()
        ]
      end)

    Surface.show(
      :profiles,
      vstack(
        [text("New profile", style: :caption), textfield("new", placeholder: "work blue 🧪 ⏎  (name, color, emoji — any order)")] ++
          if(state.status, do: [text(state.status, style: :caption)], else: []) ++
          [divider()] ++ rows
      ),
      title: "Profiles",
      kind: :settings,
      section: "Profiles",
      order: 10,
      activate: activate
    )

    state
  end

  defp label(p), do: Enum.join(Enum.reject([p["icon"], p["name"]], &is_nil/1), " ")

  # -- private ----------------------------------------------------------------

  defp normalize(list) do
    profiles =
      list
      |> Enum.filter(&(is_map(&1) and is_binary(&1["id"]) and is_binary(&1["name"])))
      |> Enum.map(&Map.merge(%{"tint" => nil, "icon" => nil, "uuid" => nil}, &1))

    default = Enum.find(profiles, @default, &(&1["id"] == "default"))
    [default | Enum.reject(profiles, &(&1["id"] == "default"))]
  end

  defp unique_id(base, profiles) do
    ids = MapSet.new(profiles, & &1["id"])

    if MapSet.member?(ids, base),
      do: Enum.find_value(2..99, fn n -> id = "#{base}-#{n}"; if MapSet.member?(ids, id), do: nil, else: id end),
      else: base
  end

  defp present(nil), do: nil
  defp present(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
  defp present(_), do: nil

  defp uuid4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e]) |> IO.iodata_to_binary()
  end

  defp save(profiles) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), JSON.encode!(profiles))
    Bridge.cast_msg(%{op: "profiles", profiles: profiles})
    :ok
  end
end
