defmodule BowserBrain.IconFetch do
  @moduledoc "Public-network-only favicon fallback, with a pinned connection per redirect."
  import Bitwise
  @limit 4_000_000

  # These dependencies are explicit for hermetic tests; icon events cannot set them.
  def fetch(url, opts \\ []) do
    resolve = Keyword.get(opts, :resolve, &resolve/1)
    request = Keyword.get(opts, :request, &request/2)
    follow(url, resolve, request, 3)
  rescue
    ArgumentError -> {:error, :invalid_url}
  end

  defp follow(url, resolve, request, redirects) do
    with {:ok, uri, addresses} <- destination(url, resolve),
         {:ok, status, headers, body} <- request.(uri, hd(addresses)) do
      cond do
        status in 200..299 and byte_size(body) <= @limit ->
          {:ok, body}

        status in [301, 302, 303, 307, 308] and redirects > 0 ->
          case Map.get(headers, "location") do
            location when is_binary(location) ->
              follow(URI.merge(uri, location) |> URI.to_string(), resolve, request, redirects - 1)

            _ ->
              {:error, :redirect}
          end

        true ->
          {:error, :http_status}
      end
    end
  end

  def destination(url, resolver \\ &resolve/1) do
    with true <- is_binary(url) and byte_size(url) <= 4096,
         false <- Regex.match?(~r/[\x00-\x20\x7f\\]/, url),
         {:ok, %URI{scheme: scheme, host: host, userinfo: nil, port: port} = uri} <- URI.new(url),
         true <- scheme in ["http", "https"] and is_binary(host) and port in 1..65535,
         true <- valid_host?(host),
         {:ok, [_ | _] = addresses} <- resolver.(host),
         true <- Enum.all?(addresses, &public_address?/1) do
      # Rebuild rather than retaining a parser-specific authority string.
      {:ok, %{uri | authority: nil, fragment: nil}, Enum.uniq(addresses)}
    else
      _ -> {:error, :destination}
    end
  end

  defp valid_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _} ->
        true

      _ ->
        byte_size(host) <= 253 and
          Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?\.?\z/, host)
    end
  end

  defp resolve(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        {:ok, [address]}

      _ ->
        results =
          for family <- [:inet, :inet6],
              do: :inet.getaddrs(String.to_charlist(host), family, 1_000)

        if Enum.all?(results, fn result ->
             match?({:ok, _}, result) or result == {:error, :nxdomain}
           end) do
          {:ok,
           Enum.flat_map(results, fn
             {:ok, addresses} -> addresses
             _ -> []
           end)}
        else
          {:error, :dns}
        end
    end
  end

  # Exclude special-use IPv4 space (IANA), multicast and reserved ranges.
  def public_address?({a, b, c, d})
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    not (a in [0, 10, 127] or a >= 224 or
           (a == 100 and b in 64..127) or (a == 169 and b == 254) or
           (a == 172 and b in 16..31) or (a == 192 and b == 168) or
           (a == 192 and b == 0 and c in [0, 2]) or (a == 192 and b == 88 and c == 99) or
           (a == 198 and b in [18, 19]) or (a == 198 and b == 51 and c == 100) or
           (a == 203 and b == 0 and c == 113))
  end

  def public_address?(address) when is_tuple(address) and tuple_size(address) == 8 do
    parts = Tuple.to_list(address)

    if Enum.all?(parts, &(is_integer(&1) and &1 in 0..65535)) do
      [a, b | _] = parts
      # Global unicast only; also exclude protocol assignments, documentation,
      # Teredo/6to4 and translation encodings that can carry private IPv4 addresses.
      a in 0x2000..0x3FFF and not (a == 0x2001 and b < 0x0200) and
        not (a == 0x2001 and b == 0x0DB8) and a != 0x2002 and
        not (a == 0x3FFF and b >>> 12 == 0)
    else
      false
    end
  end

  def public_address?(_), do: false

  def curl_args(uri, address) do
    ip = :inet.ntoa(address) |> to_string()
    ip = if tuple_size(address) == 8, do: "[#{ip}]", else: ip

    [
      "--disable",
      "--silent",
      "--globoff",
      "--proxy",
      "",
      "--noproxy",
      "*",
      "--proto",
      "=http,https",
      "--max-time",
      "3",
      "--max-filesize",
      "4000000",
      "--include",
      "--connect-to",
      "::#{ip}:#{uri.port}",
      "--url",
      URI.to_string(uri)
    ]
  end

  defp request(uri, address) do
    port =
      Port.open({:spawn_executable, ~c"/usr/bin/curl"}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: Enum.map(curl_args(uri, address), &String.to_charlist/1)
      ])

    try do
      with {:ok, data} <- collect(port, System.monotonic_time(:millisecond) + 4_000, [], 0),
           do: response(data)
    after
      if Port.info(port) do
        if {:os_pid, pid} = Port.info(port, :os_pid),
          do: System.cmd("/bin/kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)

        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end
      end
    end
  end

  defp collect(port, deadline, chunks, size) do
    receive do
      {^port, {:data, bytes}} when size + byte_size(bytes) <= @limit + 65_536 ->
        collect(port, deadline, [bytes | chunks], size + byte_size(bytes))

      {^port, {:data, _}} ->
        {:error, :too_large}

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, _}} ->
        {:error, :fetch}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> {:error, :timeout}
    end
  end

  defp response(data) do
    case :binary.split(data, "\r\n\r\n") do
      [header, body] when byte_size(header) <= 65_536 ->
        [status | lines] = String.split(header, "\r\n")

        with [_, code] <- Regex.run(~r/\AHTTP\/[0-9.]+ ([0-9]{3})(?: |\z)/, status),
             {code, ""} <- Integer.parse(code) do
          headers =
            Enum.reduce(lines, %{}, fn line, acc ->
              case String.split(line, ":", parts: 2) do
                [name, value] -> Map.put(acc, String.downcase(name), String.trim(value))
                _ -> acc
              end
            end)

          if code in 100..199, do: response(body), else: {:ok, code, headers, body}
        else
          _ -> {:error, :response}
        end

      _ ->
        {:error, :response}
    end
  end
end
