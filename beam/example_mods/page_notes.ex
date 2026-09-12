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
      Chrome.put_toolbar("page_notes_sidebar", content, edge: :right, size: 360,
        style: %{palette: palette(), foreground: :text, background: :surface, border: :separator})
      s
    else
      Chrome.remove_toolbar("page_notes_sidebar")
      s
    end
  end
  # One palette supplies the same native colors to the editor, preview and tools.
  defp palette do
    %{
      accent: %{light: "#7253A1", dark: "#C2A7F0", high_contrast_light: "#4B237C", high_contrast_dark: "#E2CCFF"},
      surface: %{light: "#FAF9FC", dark: "#252329", high_contrast_light: "#FFFFFF", high_contrast_dark: "#000000"},
      editor_background: :surface,
      text: %{light: "#302B3A", dark: "#EDE9F5", high_contrast_light: "#000000", high_contrast_dark: "#FFFFFF"},
      secondary_text: %{light: "#655E70", dark: "#BDB5CB", high_contrast_light: "#302B3A", high_contrast_dark: "#EDE9F5"}
    }
  end
  defp contents(s) do
    supported = is_binary(s.url) and URI.parse(s.url).scheme in ["http", "https"]
    header = View.hstack([
      View.image(symbol: "note.text", size: 18), View.text("Page Notes", style: :heading), View.spacer(),
      View.action("Close notes", event: "page_notes_toggle", command: View.command(:discard),
        symbol: "xmark", label_style: :icon, button_style: :plain, help: "Close notes", padding: 6)
    ], spacing: 8)
    if supported do
      key = Base.url_encode64(:crypto.hash(:sha256, s.url), padding: false)
      contexts = Map.put_new(s.contexts, key, %{url: s.url, body: body(s.url)})
      tools = View.flow([
        tool("Heading", "textformat.size", "# ", ""),
        tool("Bold", "bold", "**", "**"),
        tool("Italic", "italic", "*", "*"),
        tool("List", "list.bullet", "- ", ""),
        tool("Quote", "text.quote", "> ", ""),
        tool("Code", "chevron.left.forwardslash.chevron.right", "`", "`"),
        tool("Link", "link", "[", "](https://)"),
        View.action("Undo", symbol: "arrow.uturn.backward", label_style: :icon, button_style: :plain,
          command: View.command(:undo, field: "body"), help: "Undo", width: 28, height: 28)
      ], spacing: 6, padding: 4)
      editor = View.editor(:body, label: "Page note", monospaced: true,
        placeholder: "Write a note for this page…", fill_width: true, fill_height: true)
      pages = View.switch(:mode, [
        %{key: "write", value: "write", content: View.vstack([tools, View.divider(), editor], spacing: 8, fill_height: true)},
        %{key: "preview", value: "preview", content: View.preview(:body, fill_height: true)}
      ], fill_height: true, fill_width: true)
      footer = View.hstack([
        View.spacer(),
        View.action("Revert", command: View.command(:reset), button_style: :borderless),
        View.action("Save", command: View.command(:submit), event: "notes_save:" <> key, role: :primary, shortcut: "s")
      ])
      tree = View.state("page-note-" <> key, %{"body" => body(s.url), "mode" => "write"},
        View.vstack([
          header,
          View.text(s.url, style: :caption),
          View.selector(:mode, [%{value: "write", label: "Write"}, %{value: "preview", label: "Preview"}], label: "Note view"),
          pages, footer
        ], spacing: 12, fill_height: true, fill_width: true),
        response: s.response, tracked_fields: [:body], padding: 16, fill_width: true, fill_height: true)
      {tree, %{s | contexts: contexts}}
    else
      {View.vstack([header, View.text("Select a website to write a note.")], padding: 12, fill_width: true), s}
    end
  end
  # These are ordinary mod components; their layout and commands can be changed
  # independently of the native editor, including by composing other helpers.
  defp tool(label, symbol, prefix, suffix) do
    View.action(label, symbol: symbol, label_style: :icon, button_style: :plain,
      command: View.command(:wrap, field: "body", prefix: prefix, suffix: suffix),
      help: label, width: 28, height: 28)
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
