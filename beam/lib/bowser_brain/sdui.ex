defmodule BowserBrain.SDUI do
  @moduledoc """
  Server-Driven UI declarations (ADR 0011): the editable "mod" unit for the
  iOS runtime. A declaration is a JSON tree of native components — the phone
  renders it with real SwiftUI, never a webview. New app = new tree; edit =
  edit the tree; both are data, not code (Apple 2.5.2).

  Node shape:

      %{"type" => "vstack" | "hstack" | "text" | "image" | "spacer",
        "props" => %{...},        # static: padding, spacing, size, weight, color
        "bind" => "field.path",   # optional: pull value from the data item
        "children" => [node, ...]}

  A screen wraps a list whose `item` is a template rendered once per datum:

      %{"type" => "screen", "title" => "Home",
        "list" => %{"data" => "tweets", "item" => <template>}}

  This module builds the DEFAULT X timeline declaration; an agent (or the
  owner) mutates the tree to restyle it. The builders are pure and tested —
  the declaration is the contract the iOS renderer implements.
  """

  @doc "The default X timeline screen: a list of tweet cards."
  def x_timeline(title \\ "Home") do
    %{
      "type" => "screen",
      "title" => title,
      "list" => %{"data" => "tweets", "item" => tweet_card()}
    }
  end

  @doc "The default tweet card template — bound to a normalized tweet."
  def tweet_card do
    vstack([
      hstack(
        [
          text(bind: "name", props: %{"weight" => "bold"}),
          text(bind: "handle", props: %{"color" => "secondary"}),
          spacer(),
          text(bind: "timestamp", props: %{"color" => "secondary", "size" => 12, "relative" => true})
        ],
        props: %{"spacing" => 6}
      ),
      text(bind: "text", props: %{"size" => 15}),
      image(bind: "photos.0", props: %{"height" => 200, "corner" => 12}),
      hstack(
        [
          metric("bubble.left", "metrics.replies"),
          metric("arrow.2.squarepath", "metrics.reposts"),
          metric("heart", "metrics.likes"),
          metric("chart.bar", "metrics.views")
        ],
        props: %{"spacing" => 22, "top" => 6}
      )
    ], props: %{"padding" => 14, "spacing" => 6, "divider" => true})
  end

  @doc """
  "Big" — a media-forward wall: each tweet is a full-bleed hero image with a
  gradient scrim and the handle + text overlaid at the bottom. A completely
  different app from x_timeline, built on the same data — the "iOS mod".
  """
  def x_gallery(title \\ "Big") do
    %{"type" => "screen", "title" => title, "list" => %{"data" => "tweets", "item" => hero_card()}}
  end

  def hero_card do
    zstack(
      [
        image(bind: "photos.0", props: %{"height" => 380, "fill" => true}),
        %{"type" => "gradient", "props" => %{"height" => 380}},
        vstack(
          [
            text(bind: "name", props: %{"weight" => "bold", "color" => "white", "size" => 17}),
            text(bind: "handle", props: %{"color" => "white", "size" => 13}),
            text(bind: "text", props: %{"color" => "white", "size" => 15}),
            hstack(
              [
                %{"type" => "icon", "props" => %{"symbol" => "heart.fill", "size" => 13, "color" => "white"}},
                text(bind: "metrics.likes", props: %{"color" => "white", "size" => 13, "weight" => "bold"}),
                %{"type" => "icon", "props" => %{"symbol" => "eye.fill", "size" => 13, "color" => "white"}},
                text(bind: "metrics.views", props: %{"color" => "white", "size" => 13})
              ],
              props: %{"spacing" => 6, "top" => 4}
            )
          ],
          props: %{"padding" => 16, "spacing" => 3}
        )
      ],
      props: %{"align" => "bottomLeading"}
    )
  end

  # -- component builders (pure) ----------------------------------------------

  def zstack(children, opts \\ []), do: container("zstack", children, opts)

  def vstack(children, opts \\ []), do: container("vstack", children, opts)
  def hstack(children, opts \\ []), do: container("hstack", children, opts)

  def text(opts) do
    node("text", opts)
  end

  def image(opts) do
    node("image", opts)
  end

  def spacer, do: %{"type" => "spacer"}

  # An icon + a bound count, side by side — the metrics row unit.
  def metric(symbol, bind) do
    hstack(
      [
        %{"type" => "icon", "props" => %{"symbol" => symbol, "size" => 13, "color" => "secondary"}},
        text(bind: bind, props: %{"size" => 13, "color" => "secondary"})
      ],
      props: %{"spacing" => 5}
    )
  end

  defp container(type, children, opts) do
    %{"type" => type, "children" => children}
    |> maybe_put("props", Keyword.get(opts, :props))
  end

  defp node(type, opts) do
    %{"type" => type}
    |> maybe_put("bind", Keyword.get(opts, :bind))
    |> maybe_put("props", Keyword.get(opts, :props))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
