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
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".bowser")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("brain.sock").path

        Thread.detachNewThread { [weak self] in
            self?.listenLoop(path: path)
        }
    }

    // MARK: - Outbound

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
            close(connFD)
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
            return tab
        }
        send(["op": "hello", "v": 1, "webviews": ids, "tabs": tabs])
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

        case "set_user_content":
            let scripts = message["scripts"] as? [String]
            let styles = message["styles"] as? [String]
            let reload = message["reload"] as? Bool ?? true
            resolve(requested)?.applyUserContent(scripts: scripts, styles: styles, reload: reload)

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

        case "chrome":
            ChromeSurface.handle(message)

        case "surface":
            SurfaceManager.shared.handle(message)

        case "activate_tab":
            if let view = EngineView.live[requested] {
                view.window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }

        case "close_tab":
            EngineView.live[requested]?.window?.performClose(nil)

        default:
            NSLog("Bowser: unknown brain op \(op)")
        }
    }

    nonisolated private static func jsonify(_ value: Any?) -> Any {
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
