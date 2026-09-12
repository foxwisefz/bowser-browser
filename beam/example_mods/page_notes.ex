# bowser-profile: default
# Native document editing example. Note bodies stay in Store and native form events.
defmodule PageNotes do
  use BowserBrain.Mod
  alias BowserBrain.{Chrome, Page, Store, Surface, View}

  defp defaults, do: %{active: nil, url: nil, contexts: %{}, response: nil}
  def init_mod(_) do
    mount()
    render(defaults())
  end
  def handle_event(event, state), do: dispatch(event, Map.merge(defaults(), state))
  defp mount do
    Page.set_scripts([])
    Chrome.add_menu_item("page_notes_toggle", "Toggle Page Notes")
    Chrome.put_toolbar("page_notes", View.hstack([
      View.action("Page Notes", event: "page_notes_toggle")
    ]), edge: :bottom, size: 30)
  end
  defp dispatch(%{"event" => "hello"} = e, s) do
    mount()
    sync(%{s | active: e["active"]}) |> render()
  end
  defp dispatch(%{"event" => "mod_reloaded"}, s) do
    mount()
    sync(s) |> render()
  end
  defp dispatch(%{"event" => "tab_activated", "webview" => id}, s), do: sync(%{s | active: id}) |> render()
  defp dispatch(%{"event" => "url_changed", "webview" => id}, %{active: id} = s), do: sync(s) |> render()
  defp dispatch(%{"event" => "chrome_click", "id" => "page_notes_toggle"}, s), do: toggle(s)
  defp dispatch(%{"event" => "surface", "surface" => surface, "id" => action} = e, s)
       when surface in ["toolbar:page_notes", "toolbar:page_notes_sidebar"] do
    case action do
      "page_notes_toggle" -> toggle(s)
      "notes_save:" <> key -> save(e["value"], key, s)
      _ -> s
    end
  end
  # Page-origin messages have no note read/write capability.
  defp dispatch(_, s), do: s
  defp toggle(s) do
    Store.put(__MODULE__, "visible", not Store.get(__MODULE__, "visible", true))
    sync(s) |> render()
  end
  defp sync(s) do
    case Surface.tab_layout(s.active || 0) do
      {:ok, live} ->
        active = live["active"] || s.active
        tab = Enum.find(live["tabs"] || [], &(&1["webview"] == active))
        url = if tab, do: tab["url"]
        %{s | active: active, url: url, response: if(url == s.url, do: s.response)}
      _ -> s
    end
  end
  defp body(url), do: get_in(Store.get(__MODULE__, "notes", %{}), [url, "body"]) || ""
  defp render(s) do
    if Store.get(__MODULE__, "visible", true) do
      {content, s} = contents(s)
      Chrome.put_toolbar("page_notes_sidebar", content, edge: :right, size: 360)
      s
    else
      Chrome.remove_toolbar("page_notes_sidebar")
      s
    end
  end
  defp contents(s) do
    supported = is_binary(s.url) and URI.parse(s.url).scheme in ["http", "https"]
    header = View.hstack([View.text("Page Notes", style: :heading), View.action("Close", event: "page_notes_toggle")])
    if supported do
      key = Base.url_encode64(:crypto.hash(:sha256, s.url), padding: false)
      contexts = Map.put_new(s.contexts, key, %{url: s.url, body: body(s.url)})
      actions = [
        %{label: "H1", prefix: "# ", suffix: ""},
        %{label: "B", help: "Bold", prefix: "**", suffix: "**"},
        %{label: "I", help: "Italic", prefix: "*", suffix: "*"},
        %{label: "List", prefix: "- ", suffix: ""},
        %{label: "Quote", prefix: "> ", suffix: ""},
        %{label: "Code", prefix: "`", suffix: "`"},
        %{label: "Link", prefix: "[", suffix: "](https://)"}
      ]
      editor = View.input(:body, kind: :multiline, label: "Page note", monospaced: true,
        preview: :markdown, editor_actions: actions, placeholder: "Write a note for this page…",
        fill_width: true, fill_height: true)
      form = View.form("page-note-" <> key, %{"body" => body(s.url)}, editor,
        event: "notes_save:" <> key, response: s.response, submit_label: "Save",
        fill_width: true, fill_height: true)
      tree = View.vstack([header, View.text(s.url, style: :caption), form],
        padding: 12, fill_width: true, fill_height: true)
      {tree, %{s | contexts: contexts}}
    else
      {View.vstack([header, View.text("Select a website to write a note.")], padding: 12, fill_width: true), s}
    end
  end
  defp save(%{"request_id" => request, "values" => %{"body" => value} = values}, key, s) when is_binary(value) do
    case s.contexts[key] do
      nil -> s
      context ->
        cond do
          byte_size(value) > 500_000 ->
            render(%{s | response: View.form_response(request, {:error, %{"body" => "Maximum note size is 500 KB."}})})
          body(context.url) != context.body ->
            render(%{s | response: View.form_response(request, {:error, %{"body" => "This note changed elsewhere. Your draft is preserved."}})})
          true ->
            case Store.update(__MODULE__, "notes", %{}, fn notes ->
              Map.put(notes, context.url, %{"body" => value, "updated_at" => System.system_time(:second)})
            end) do
              {:ok, _} ->
                contexts = Map.put(s.contexts, key, %{context | body: value})
                render(%{s | contexts: contexts, response: View.form_response(request, {:ok, values})})
              {:error, _} ->
                render(%{s | response: View.form_response(request, {:error, "Could not save. Your draft is preserved."})})
            end
        end
    end
  end
  defp save(_, _, s), do: s
end
