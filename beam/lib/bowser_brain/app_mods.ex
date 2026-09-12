defmodule BowserBrain.AppMods do
  @moduledoc "Payload storage and the ModSmith toolbox scoped to one saved app."
  alias BowserBrain.{Bridge, ModSmith, Paths}

  def valid_id?(id),
    do: is_binary(id) and Regex.match?(~r/^com\.foxwiseai\.bowser\.site\.[0-9a-f]{16}$/, id)

  def root,
    do: Application.get_env(:bowser_brain, :app_mods_dir, Path.join(Paths.home(), "app-mods"))

  def config(id) do
    if valid_id?(id) do
      key = String.replace_prefix(id, "com.foxwiseai.bowser.site.", "")

      base =
        Application.get_env(:bowser_brain, :site_apps_dir, Path.join(Paths.home(), "site-apps"))

      with {:ok, data} <- File.read(Path.join([base, key, "app.json"])),
           {:ok, %{"identifier" => ^id, "url" => url} = config} <- JSON.decode(data),
           %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) <-
             URI.parse(url) do
        {:ok, config}
      else
        _ -> {:error, "saved app is not registered"}
      end
    else
      {:error, "invalid saved-app id"}
    end
  end

  def payloads(id) do
    if valid_id?(id) do
      for path <- Path.wildcard(Path.join([root(), id, "*.{css,js}"])),
          do: {Path.basename(path), File.read!(path)}
    else
      []
    end
  end

  def filename(path, host, id) when is_binary(path) do
    name = Path.basename(path)
    allowed = path in [name, "sites/#{host}/#{name}", "app-mods/#{id}/#{name}"]

    if allowed and Regex.match?(~r/^[A-Za-z0-9_-][A-Za-z0-9._-]*\.(css|js)$/, name) and
         not String.contains?(name, ".."),
       do: {:ok, name},
       else: {:error, "app mods must be CSS/JS files inside this app"}
  end

  def filename(_, _, _), do: {:error, "invalid app mod path"}

  def put(id, name, content) when is_binary(content) do
    with {:ok, config} <- config(id),
         {:ok, name} <- filename(name, URI.parse(config["url"]).host, id),
         true <- byte_size(content) <= 200_000 do
      path = Path.join([root(), id, name])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path <> ".tmp", content)
      File.rename!(path <> ".tmp", path)
      {:ok, "app-mods/#{id}/#{name}"}
    else
      false -> {:error, "file too large"}
      error -> error
    end
  end

  def install_result({:error, _} = error, _app), do: error

  def install_result({:output, output}, app) do
    with {:ok, envelope} <- ModSmith.extract_json(output),
         "payload" <- Map.get(envelope, "tier", "payload"),
         files when is_list(files) and files != [] <- envelope["files"],
         :ok <- validate_files(files, app) do
      results = Enum.map(files, fn file -> put(app["id"], file["path"], file["content"]) end)

      case Enum.find(results, &match?({:error, _}, &1)) do
        nil -> {:ok, envelope["summary"] || "App mod installed", Enum.map(results, &elem(&1, 1))}
        error -> error
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "saved-app mods require a payload envelope with CSS/JS files"}
    end
  end

  def validate_files(files, app) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      with %{"path" => path, "content" => content} when is_binary(content) <- file,
           true <- byte_size(content) <= 200_000,
           {:ok, _} <- filename(path, URI.parse(app["url"]).host, app["id"]) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, "file outside this app's CSS/JS scope or too large"}}
      end
    end)
  end

  def dispatch(tool, args, id) do
    with {:ok, config} <- config(id) do
      dispatch_scoped(tool, args, id, config)
    else
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  defp dispatch_scoped("list_tabs", _args, id, config),
    do: %{ok: true, active: 0, tabs: [%{webview: 0, url: config["url"], app: id}]}

  defp dispatch_scoped("page_eval", args, id, _), do: evaluate(id, args["js"] || "")

  defp dispatch_scoped("page_html", args, id, _) do
    js =
      "(()=>{const el=document.querySelector(#{JSON.encode!(args["selector"] || "body")});return el ? el.outerHTML.slice(0,20000) : 'NO MATCH';})()"

    case evaluate(id, js) do
      %{ok: true, value: value} -> %{ok: true, html: value}
      error -> error
    end
  end

  defp dispatch_scoped("put_payload", args, id, _) do
    case put(id, args["name"] || "", args["content"] || "") do
      {:ok, path} ->
        %{ok: true, installed: path, applies: "only this saved app, within one second"}

      {:error, reason} ->
        %{ok: false, error: reason}
    end
  end

  defp dispatch_scoped("list_mods", _, id, _) do
    %{
      ok: true,
      files:
        Enum.map(payloads(id), fn {name, _} -> %{path: "app-mods/#{id}/#{name}", scope: id} end)
    }
  end

  defp dispatch_scoped("read_mod", args, id, config) do
    with {:ok, name} <- filename(args["path"], URI.parse(config["url"]).host, id),
         {:ok, content} <- File.read(Path.join([root(), id, name])) do
      %{ok: true, content: content}
    else
      _ -> %{ok: false, error: "app mod not found"}
    end
  end

  defp dispatch_scoped(_, _, _, _), do: %{ok: false, error: "tool unavailable in saved-app scope"}

  defp evaluate(id, js) do
    case Bridge.eval_site_js(id, js, 10_000) do
      {:ok, value} -> %{ok: true, value: value}
      {:error, reason} -> %{ok: false, error: inspect(reason)}
    end
  end
end
