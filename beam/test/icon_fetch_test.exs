defmodule BowserBrain.IconFetchTest do
  use ExUnit.Case, async: true
  alias BowserBrain.IconFetch

  test "rejects local, private, special-use and encoded addresses before requesting" do
    addresses = [
      "0.0.0.0",
      "127.0.0.1",
      "127.1",
      "2130706433",
      "10.0.0.1",
      "100.64.0.1",
      "169.254.169.254",
      "172.16.0.1",
      "192.168.1.1",
      "192.0.0.1",
      "192.0.2.1",
      "192.88.99.1",
      "198.18.0.1",
      "198.51.100.1",
      "203.0.113.1",
      "224.0.0.1",
      "240.0.0.1",
      "255.255.255.255",
      "[::1]",
      "[::]",
      "[fc00::1]",
      "[fe80::1]",
      "[::ffff:127.0.0.1]",
      "[64:ff9b::7f00:1]",
      "[2001::1]",
      "[2001:db8::1]",
      "[2002:7f00:1::]",
      "[3fff::1]"
    ]

    for host <- addresses do
      assert {:error, _} =
               IconFetch.fetch("http://#{host}/favicon.ico",
                 request: fn _, _ -> flunk("requested #{host}") end
               )
    end

    assert {:error, _} =
             IconFetch.destination("http://cdn.example/icon", fn _ ->
               {:ok, [{8, 8, 8, 8}, {127, 0, 0, 1}]}
             end)

    assert {:error, _} = IconFetch.destination("http://cdn.example/icon", fn _ -> {:ok, []} end)
  end

  test "URL parsing fails closed on credentials, controls, zones and authority ambiguity" do
    for url <- [
          "file:///etc/passwd",
          "http://user:pass@cdn.example/icon",
          "http://cdn.example\\@localhost/",
          "http://[fe80::1%25en0]/",
          "http://%31%32%37.0.0.1/",
          "http://cdn.example\n/",
          "http://cdn.example:0/",
          "http://cdn.example:65536/",
          "http:///icon",
          "http://{cdn,localhost}/"
        ] do
      assert {:error, _} = IconFetch.destination(url, fn _ -> {:ok, [{8, 8, 8, 8}]} end)
    end
  end

  test "follows public CDN and relative redirects with fresh checks and pinned numeric addresses" do
    parent = self()

    resolver = fn host ->
      send(parent, {:dns, host})
      {:ok, [if(host == "cdn.example", do: {1, 1, 1, 1}, else: {8, 8, 8, 8})]}
    end

    request = fn uri, ip ->
      send(parent, {:request, URI.to_string(uri), ip})

      case uri.path do
        "/icon" -> {:ok, 302, %{"location" => "https://cdn.example/next"}, ""}
        "/next" -> {:ok, 307, %{"location" => "/final"}, ""}
        "/final" -> {:ok, 200, %{}, "PNG"}
      end
    end

    assert {:ok, "PNG"} =
             IconFetch.fetch("https://site.example/icon", resolve: resolver, request: request)

    assert_received {:request, "https://site.example/icon", {8, 8, 8, 8}}
    assert_received {:request, "https://cdn.example/next", {1, 1, 1, 1}}
    assert_received {:request, "https://cdn.example/final", {1, 1, 1, 1}}
    assert_received {:dns, "cdn.example"}
    assert_received {:dns, "cdn.example"}
  end

  test "blocks redirect to loopback or rebinding of the same hostname" do
    for location <- [
          "http://127.0.0.1/private",
          "http://cdn.example/private",
          "file:///etc/passwd"
        ] do
      key = make_ref()

      resolver = fn _ ->
        case Process.get(key) do
          nil ->
            Process.put(key, true)
            {:ok, [{8, 8, 8, 8}]}

          _ ->
            {:ok, [{127, 0, 0, 1}]}
        end
      end

      request = fn uri, _ ->
        assert uri.path == "/icon"
        {:ok, 302, %{"location" => location}, ""}
      end

      assert {:error, _} =
               IconFetch.fetch("http://cdn.example/icon", resolve: resolver, request: request)
    end
  end

  test "bounds redirects and response size" do
    resolve = fn _ -> {:ok, [{8, 8, 8, 8}]} end

    assert {:error, :http_status} =
             IconFetch.fetch("http://cdn.example/icon",
               resolve: resolve,
               request: fn _, _ -> {:ok, 302, %{"location" => "/icon"}, ""} end
             )

    assert {:error, _} =
             IconFetch.fetch("http://cdn.example/icon",
               resolve: resolve,
               request: fn _, _ -> {:ok, 200, %{}, :binary.copy("x", 4_000_001)} end
             )
  end

  test "curl pins IPv4 and IPv6 while retaining URL TLS identity and disabling ambient routing" do
    uri = URI.new!("https://cdn.example/icon")

    for {ip, destination} <- [
          {{8, 8, 8, 8}, "::8.8.8.8:443"},
          {{0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}, "::[2606:4700:4700::1111]:443"}
        ] do
      assert IconFetch.public_address?(ip)
      args = IconFetch.curl_args(uri, ip)
      assert hd(args) == "--disable"
      pairs = Enum.chunk_every(args, 2, 1, :discard)
      assert ["--connect-to", destination] in pairs
      assert ["--proxy", ""] in pairs
      assert ["--noproxy", "*"] in pairs
      assert ["--url", "https://cdn.example/icon"] in pairs
      assert "--globoff" in args
      refute "--location" in args
      refute "--insecure" in args
    end
  end

  test "real loopback listener receives no favicon request" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)
    assert {:error, :destination} = IconFetch.fetch("http://127.0.0.1:#{port}/favicon.ico")
    assert {:error, :timeout} = :gen_tcp.accept(listener, 50)
  end

  test "curl's actual connection is pinned and does not follow redirects or ambient proxy settings" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, client} = :gen_tcp.accept(listener, 2_000)
        {:ok, request} = :gen_tcp.recv(client, 0, 2_000)

        :ok =
          :gen_tcp.send(
            client,
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:#{port}/private\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          )

        :gen_tcp.close(client)
        request
      end)

    # Test the transport command against our controlled listener. Production's
    # destination check rejects this address, as the preceding test verifies.
    uri = URI.new!("http://unresolvable.invalid:#{port}/favicon.ico")

    {response, 0} =
      System.cmd("/usr/bin/curl", IconFetch.curl_args(uri, {127, 0, 0, 1}),
        env: [{"http_proxy", "http://127.0.0.1:1"}, {"ALL_PROXY", "http://127.0.0.1:1"}]
      )

    assert response =~ "HTTP/1.1 302"
    assert Task.await(server) =~ "Host: unresolvable.invalid:#{port}"
    assert {:error, :timeout} = :gen_tcp.accept(listener, 50)
  end
end
