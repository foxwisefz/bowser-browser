import AppKit
import WebKit

/// Swift-native implementation of the brain protocol (ADR 0008): a Unix
/// socket listener at ~/.bowser/brain.sock speaking {packet,4}-framed JSON —
/// byte-compatible with the old Rust host, so the Elixir brain is unchanged.
///
/// Socket I/O runs on a dedicated thread; every message is handled on the
/// main actor where WebKit lives. One brain connection at a time; the brain
/// reconnects freely.
@MainActor
final class BrainBridge {
    static let shared = BrainBridge()

    // Written by the socket thread, read under lock by send().
    private let connLock = NSLock()
    nonisolated(unsafe) private var connFD: Int32 = -1

    func start() {
        let dir = SiteAppConfiguration.current?.home ?? BowserPaths.home
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if SiteAppConfiguration.current != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        let path = dir.appendingPathComponent("brain.sock").path

        Self.spawnListener(self, path: path)
    }

    /// The listener thread is spawned from a NONISOLATED context: a closure
    /// formed inside a @MainActor method inherits main-actor isolation, and
    /// Swift's strict executor checks (on for a real app bundle; lenient for
    /// the bare dev binary) trap the moment it runs on the detached thread —
    /// SIGTRAP on every launch of the installed Bowser.app.
    nonisolated private static func spawnListener(_ bridge: BrainBridge, path: String) {
        Thread.detachNewThread {
            bridge.listenLoop(path: path)
        }
    }

    // MARK: - Outbound

    var isConnected: Bool {
        connLock.lock()
        defer { connLock.unlock() }
        return connFD >= 0
    }

    func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let payload = try? JSONSerialization.data(withJSONObject: message)
        else {
            NSLog("Bowser: refusing to send non-JSON message")
            return
        }
        var frame = Data(capacity: payload.count + 4)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)

        connLock.lock()
        defer { connLock.unlock() }
        guard connFD >= 0 else { return }
        let ok = frame.withUnsafeBytes { raw -> Bool in
            var written = 0
            while written < raw.count {
                let n = write(connFD, raw.baseAddress!.advanced(by: written), raw.count - written)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
        if !ok {
            shutdown(connFD, SHUT_RDWR) // readLoop owns the close
            connFD = -1
        }
    }

    // MARK: - Socket thread

    nonisolated private func listenLoop(path: String) {
        unlink(path)
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            NSLog("Bowser: brain socket() failed")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let copied = path.withCString { src -> Bool in
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
            guard strlen(src) <= maxLen else { return false }
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dst in
                    _ = strcpy(dst, src)
                }
            }
            return true
        }
        guard copied else {
            NSLog("Bowser: socket path too long")
            return
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(listenFD, 1) == 0 else {
            NSLog("Bowser: brain socket bind/listen failed")
            close(listenFD)
            return
        }
        NSLog("Bowser: brain socket listening at \(path)")

        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                NSLog("Bowser: brain accept failed")
                break
            }
            // The main browser can quit while a site is emitting events.
            // A disconnected peer must not terminate that app with SIGPIPE.
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            NSLog("Bowser: brain connected")
            connLock.lock()
            connFD = fd
            connLock.unlock()

            DispatchQueue.main.async { BrainBridge.shared.sendHello() }
            readLoop(fd: fd)

            connLock.lock()
            if connFD == fd { connFD = -1 }
            connLock.unlock()
            close(fd)
            NSLog("Bowser: brain disconnected")
        }
        close(listenFD)
    }

    nonisolated private func readLoop(fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)

        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])

            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard length <= 64 * 1024 * 1024 else { return }
                guard buffer.count >= 4 + length else { break }
                let payload = buffer.subdata(in: 4..<(4 + length))
                buffer.removeSubrange(0..<(4 + length))

                // Data is Sendable; parse on the main actor where handling lives.
                DispatchQueue.main.async {
                    if let object = try? JSONSerialization.jsonObject(with: payload),
                       let message = object as? [String: Any] {
                        BrainBridge.shared.handle(message)
                    } else {
                        NSLog("Bowser: bad JSON from brain")
                    }
                }
            }
        }
    }

    // MARK: - Protocol (main actor)

    private func sendHello() {
        let ids = EngineView.live.keys.sorted()
        let tabs: [[String: Any]] = ids.map { id in
            var tab: [String: Any] = ["id": id]
            // Never box an Optional into JSON — JSONSerialization rejects it
            // and the whole hello silently dies.
            if let url = EngineView.live[id]?.currentURLString {
                tab["url"] = url
            } else {
                tab["url"] = NSNull()
            }
            // Live title too: an already-loaded page will never fire another
            // title_changed, so hello is the only chance to learn it.
            if let title = EngineView.live[id]?.webView.title, !title.isEmpty {
                tab["title"] = title
            }
            if let favicon = EngineView.live[id]?.faviconPath {
                tab["favicon"] = favicon
            }
            if let profile = EngineView.live[id]?.profileId {
                tab["profile"] = profile
            }
            return tab
        }
        var hello: [String: Any] = ["op": "hello", "v": 1, "webviews": ids, "tabs": tabs]
        if let active = (NSApp.delegate as? AppDelegate)?.currentWebviewId {
            hello["active"] = active
        }
        send(hello)
    }

    private func resolve(_ requested: UInt64) -> EngineView? {
        if requested != 0, let view = EngineView.live[requested] { return view }
        return EngineView.live.keys.min().flatMap { EngineView.live[$0] }
    }

    private func handle(_ message: [String: Any]) {
        let op = message["op"] as? String ?? ""
        let requested = UInt64(message["webview"] as? Int ?? 0)

        switch op {
        case "navigate":
            guard let url = message["url"] as? String else { return }
            resolve(requested)?.load(urlString: url)

        case "reload":
            resolve(requested)?.webView.reload()

        case "eval_js":
            guard let id = message["id"] as? Int, let code = message["code"] as? String else { return }
            guard let view = resolve(requested) else {
                send(["op": "js_result", "id": id, "ok": false, "value": "no webview"])
                return
            }
            let webviewId = view.webviewId
            view.webView.evaluateJavaScript(code) { [weak self] value, error in
                MainActor.assumeIsolated {
                    if let error, error.localizedDescription.contains("unsupported type") {
                        // A Promise came back (async IIFE / fetch): await it.
                        // Agents lost minutes to "async eval isn't supported".
                        EngineView.live[webviewId]?.webView.callAsyncJavaScript(
                            "return (\(code));", arguments: [:], in: nil, in: .page
                        ) { result in
                            MainActor.assumeIsolated {
                                switch result {
                                case .success(let awaited):
                                    self?.send([
                                        "op": "js_result", "id": id, "webview": webviewId,
                                        "ok": true, "value": Self.jsonify(awaited),
                                    ])
                                case .failure(let asyncError):
                                    self?.send([
                                        "op": "js_result", "id": id, "webview": webviewId,
                                        "ok": false, "value": asyncError.localizedDescription,
                                    ])
                                }
                            }
                        }
                        return
                    }
                    if let error {
                        self?.send([
                            "op": "js_result", "id": id, "webview": webviewId,
                            "ok": false, "value": error.localizedDescription,
                        ])
                    } else {
                        self?.send([
                            "op": "js_result", "id": id, "webview": webviewId,
                            "ok": true, "value": Self.jsonify(value),
                        ])
                    }
                }
            }

        case "site_eval", "site_status":
            guard SiteAppConfiguration.current == nil else { return }
            SiteAppHub.shared.route(message)

        case "site_mod_status":
            SiteAppCommands.shared.updateStatus(message["text"] as? String ?? "")

        case "site_app_info":
            guard let config = SiteAppConfiguration.current else { return }
            let titles = NSApp.mainMenu?.items.flatMap { $0.submenu?.items.map(\.title) ?? [] } ?? []
            send(["op": "site_app_info", "id": message["id"] ?? 0,
                  "app": config.identifier, "profile": config.profile,
                  "windows": BrowserWindowController.all.count, "menu_titles": titles,
                  "app_mod_count": SiteAppRuntime.shared.modCount,
                  "favicon": EngineView.live.values.first?.faviconPath ?? "",
                  "actions": SiteAppCommands.Action.allCases.map(\.rawValue)])

        case "site_bootstrap":
            SiteAppRuntime.shared.bootstrap(message)

        case "set_user_content":
            if SiteAppConfiguration.current != nil {
                SiteAppRuntime.shared.updateContent(message, reload: message["reload"] as? Bool ?? true)
                return
            }
            if SiteAppConfiguration.current == nil, requested == 0 { SiteAppHub.shared.broadcastContent(message) }
            let scripts = message["scripts"] as? [String]
            let styles = message["styles"] as? [String]
            let reload = message["reload"] as? Bool ?? true
            // Remember for webviews that don't exist yet — new tabs seed
            // from this store instead of being born unmodded.
            EngineView.rememberUserContent(scripts: scripts, styles: styles)
            // webview 0 = ALL tabs: injected content is conceptually global
            // (site payloads + mod scripts self-guard by hostname). Targeting
            // only the lowest-id tab left every other tab unmodded.
            if requested == 0 {
                for view in EngineView.live.values {
                    view.applyUserContent(scripts: scripts, styles: styles, reload: reload)
                }
            } else {
                resolve(requested)?.applyUserContent(scripts: scripts, styles: styles, reload: reload)
            }

        case "get_cookies":
            guard let id = message["id"] as? Int else { return }
            let host = (message["url"] as? String).flatMap(URL.init(string:))?.host ?? ""
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                MainActor.assumeIsolated {
                    let matched = cookies.filter { c in
                        host.isEmpty || host.hasSuffix(c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                            || c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).hasSuffix(host)
                    }
                    let serialized: [[String: Any]] = matched.map { c in
                        [
                            "name": c.name, "value": c.value, "domain": c.domain,
                            "path": c.path, "secure": c.isSecure, "http_only": c.isHTTPOnly,
                        ]
                    }
                    self?.send(["op": "cookies_result", "id": id, "cookies": serialized])
                }
            }

        case "set_cookie":
            guard let spec = message["cookie"] as? [String: Any],
                  let name = spec["name"] as? String,
                  let value = spec["value"] as? String,
                  let url = (message["url"] as? String).flatMap(URL.init(string:))
            else { return }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: spec["domain"] as? String ?? url.host ?? "",
                .path: spec["path"] as? String ?? "/",
            ]
            if spec["secure"] as? Bool == true { properties[.secure] = "TRUE" }
            if let cookie = HTTPCookie(properties: properties) {
                WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
            }

        case "profiles":
            // The brain changed the profile list: refresh ours and the menu.
            Profile.apply(message["profiles"] as? [[String: Any]] ?? [])
            (NSApp.delegate as? AppDelegate)?.rebuildProfileMenu()
            for controller in BrowserWindowController.all { controller.profileDidChange() }

        case "chrome":
            ChromeSurface.handle(message)

        case "surface":
            SurfaceManager.shared.handle(message)

        case "activate_tab":
            // Mount it as the window's content — no window ordering games,
            // the tab has no window of its own any more.
            if let host = BrowserWindowController.host(of: requested),
               host.activateTab(id: requested) {
                host.window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }

        case "close_tab":
            BrowserWindowController.host(of: requested)?.closeTab(id: requested)

        case "dub_capture_start":
            if #available(macOS 13.0, *) { AudioDub.shared.start() }

        case "dub_capture_stop":
            if #available(macOS 13.0, *) { AudioDub.shared.stop() }

        case "dub_play":
            if #available(macOS 13.0, *), let mp3 = message["data"] as? String {
                AudioDub.shared.play(base64: mp3)
            }

        case "restore_done":
            // Session finished restoring and this webview is the active one:
            // the freeze-frame yields when IT paints (bowser-browser-6fa).
            BrowserWindowController.host(of: requested)?.restoreDidComplete(id: requested)

        case "warm_tab":
            // Invisible short mount so a background page can cold-start its
            // media pipeline (bowser-browser-hj1). No focus, nothing on
            // screen moves.
            BrowserWindowController.host(of: requested)?
                .warmTab(id: requested, ms: message["ms"] as? Int)

        default:
            NSLog("Bowser: unknown brain op \(op)")
        }
    }

    nonisolated static func jsonify(_ value: Any?) -> Any {
        switch value {
        case nil: return NSNull()
        case let v as NSNumber: return v
        case let v as String: return v
        case let v as [Any]: return v.map { jsonify($0) }
        case let v as [String: Any]: return v.mapValues { jsonify($0) }
        default: return String(describing: value!)
        }
    }
}
