import AppKit
import WebKit

struct SiteAppConfiguration: Codable, Equatable {
    let url: URL
    let profile: String
    let identifier: String
    let mainApp: URL

    static let current = parse(Bundle.main.infoDictionary ?? [:])

    static func parse(_ info: [String: Any]) -> Self? {
        guard info["BowserAppVersion"] as? Int == 2,
              let value = info["BowserSavedURL"] as? String, let url = URL(string: value),
              ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
              let id = info["CFBundleIdentifier"] as? String, id.hasPrefix("com.foxwiseai.bowser.site."),
              let app = info["BowserMainApp"] as? String else { return nil }
        return Self(url: url, profile: info["BowserProfile"] as? String ?? "default",
                    identifier: id, mainApp: URL(fileURLWithPath: app))
    }

    var home: URL {
        BowserPaths.home.appendingPathComponent("site-apps")
            .appendingPathComponent(identifier.replacingOccurrences(of: "com.foxwiseai.bowser.site.", with: ""))
    }
}

@MainActor
final class SiteAppRuntime {
    static let shared = SiteAppRuntime()
    private var contentTimer: Timer?
    private var inheritedScripts: [String] = []
    private var profileScripts: [String] = []
    private var profileStyles: [String] = []
    private var inheritedStyles: [String] = []
    private var appScripts: [String] = []
    var modCount: Int { appScripts.count }
    private var loaded = false
    private var receivedBootstrap = false
    private var seededStorage = false
    private weak var controller: BrowserWindowController?

    func start(_ configuration: SiteAppConfiguration, controller: BrowserWindowController) {
        self.controller = controller
        refreshMods(reload: false)
        contentTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { SiteAppRuntime.shared.refreshMods(reload: true) }
        }
        do {
            try FileManager.default.createDirectory(at: configuration.home, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(configuration).write(to: configuration.home.appendingPathComponent("app.json"), options: .atomic)
        } catch { NSLog("Bowser: site registration failed: %@", error.localizedDescription) }
        // Keep the main browser available to supply this profile's login and
        // mods. Do not activate it or steal focus from the saved app.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.foxwiseai.bowser").isEmpty {
            let options = NSWorkspace.OpenConfiguration()
            options.activates = false
            Task { @MainActor in
                do { _ = try await NSWorkspace.shared.openApplication(at: configuration.mainApp, configuration: options) }
                catch { NSLog("Bowser: main browser startup failed: %@", error.localizedDescription) }
            }
        }
        // The app's own persistent session remains usable if Bowser is down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.loadOnce() }
    }

    func bootstrap(_ message: [String: Any]) {
        guard let controller else { return }
        updateContent(message, reload: false)
        guard !receivedBootstrap else { return }
        receivedBootstrap = true
        loaded = true // reconnect must never navigate the app; a late FIRST bootstrap must apply
        if let storage = message["local_storage"] as? String,
           let script = Self.storageSeedScript(storage, url: SiteAppConfiguration.current?.url) {
            controller.activeTab.webView.configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            seededStorage = true
        }
        let store = controller.activeTab.webView.configuration.websiteDataStore.httpCookieStore
        let cookies = (message["cookies"] as? [[String: String]] ?? []).compactMap(Self.cookie)
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, let configuration = SiteAppConfiguration.current else { return }
            self.controller?.loadURL(configuration.url.absoluteString)
        }
    }

    func updateContent(_ message: [String: Any], reload: Bool) {
        if let profile = message["profile"] as? String {
            guard profile == SiteAppConfiguration.current?.profile else { return }
            if let scripts = message["scripts"] as? [String] { profileScripts = scripts }
            if let styles = message["styles"] as? [String] { profileStyles = styles }
            applyContent(reload: reload)
            return
        }
        if let scripts = message["profile_scripts"] as? [String] { profileScripts = scripts }
        if let styles = message["profile_styles"] as? [String] { profileStyles = styles }
        if let scripts = message["scripts"] as? [String] { inheritedScripts = scripts }
        if let styles = message["styles"] as? [String] { inheritedStyles = styles }
        applyContent(reload: reload)
    }

    private func applyContent(reload: Bool) {
        let scripts = inheritedScripts + profileScripts + appScripts
        let styles = inheritedStyles + profileStyles
        EngineView.rememberUserContent(scripts: scripts, styles: styles)
        for view in EngineView.live.values {
            view.applyUserContent(scripts: scripts, styles: styles, reload: reload)
        }
    }

    private func refreshMods(reload: Bool) {
        guard let config = SiteAppConfiguration.current else { return }
        let scripts = Self.modScripts(configuration: config, root: BowserPaths.home.appendingPathComponent("app-mods"))
        guard scripts != appScripts else { return }
        appScripts = scripts
        applyContent(reload: reload)
    }

    /// App files are never placed in the browser's global sites directory.
    /// Guard the saved origin as well, so OAuth and external pages stay clean.
    nonisolated static func modScripts(configuration: SiteAppConfiguration, root: URL) -> [String] {
        let directory = root.appendingPathComponent(configuration.identifier)
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["css", "js"].contains($0.pathExtension) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let url = configuration.url
        let origin = "\(url.scheme ?? "https")://\(url.host ?? "")" + (url.port.map { ":\($0)" } ?? "")
        func literal(_ value: String) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)!
        }
        return files.compactMap { file in
            guard let data = try? Data(contentsOf: file), data.count <= 200_000,
                  let content = String(data: data, encoding: .utf8) else { return nil }
            let body = file.pathExtension == "css"
                ? "const add=()=>{const s=document.createElement('style');s.textContent=\(literal(content));(document.head||document.documentElement).appendChild(s);};if(document.documentElement)add();else document.addEventListener('DOMContentLoaded',add,{once:true});"
                : content
            return "(function(){if(location.origin!==\(literal(origin)))return;\n\(body)\n})();"
        }
    }

    func pageFinished(_ view: EngineView) {
        guard seededStorage, controller?.activeTab === view else { return }
        seededStorage = false
        // Remove the one-time login seed so logging out never resurrects it.
        view.applyUserContent(scripts: nil, styles: nil, reload: false)
    }

    nonisolated static func storageSeedScript(_ storage: String, url: URL?) -> String? {
        guard let url, let host = url.host,
              let data = storage.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String], !values.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: ["origin": "\(url.scheme ?? "https")://\(host)" + (url.port.map { ":\($0)" } ?? ""), "values": values]),
              let literal = String(data: json, encoding: .utf8) else { return nil }
        return "(function(){const seed=\(literal); if(location.origin!==seed.origin)return; for(const [k,v] of Object.entries(seed.values)){if(localStorage.getItem(k)===null)localStorage.setItem(k,v);}})();"
    }

    private func loadOnce() {
        guard !loaded, let configuration = SiteAppConfiguration.current else { return }
        loaded = true
        controller?.loadURL(configuration.url.absoluteString)
    }

    nonisolated static func cookie(_ properties: [String: String]) -> HTTPCookie? {
        var values: [HTTPCookiePropertyKey: Any] = [:]
        for (key, value) in properties { values[HTTPCookiePropertyKey(key)] = value }
        if let seconds = properties[HTTPCookiePropertyKey.expires.rawValue].flatMap(Double.init) {
            values[.expires] = Date(timeIntervalSince1970: seconds)
        }
        return HTTPCookie(properties: values)
    }

    nonisolated static func matches(cookieDomain: String, host: String) -> Bool {
        let domain = cookieDomain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let host = host.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }
}

/// A separate connection per saved app; it never competes with the BEAM
/// connection on the primary brain.sock. Main-browser session events stay
/// private to the primary browser; global page-mod updates reach each app.
@MainActor
final class SiteAppHub {
    static let shared = SiteAppHub()
    private var connections: [String: SiteAppConnection] = [:]
    private var connecting = Set<String>()
    private var configurations: [String: SiteAppConfiguration] = [:]
    private var pending: [Int: String] = [:]
    private var timer: Timer?

    func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { SiteAppHub.shared.scan() }
        }
    }

    private func scan() {
        let root = BowserPaths.home.appendingPathComponent("site-apps")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            guard connections[dir.path] == nil, !connecting.contains(dir.path),
                  let data = try? Data(contentsOf: dir.appendingPathComponent("app.json")),
                  let config = try? JSONDecoder().decode(SiteAppConfiguration.self, from: data) else { continue }
            connecting.insert(dir.path)
            let key = dir.path
            SiteAppConnection.connect(path: dir.appendingPathComponent("brain.sock").path) { connection in
                self.connecting.remove(key)
                guard let connection else { return }
                self.connections[key] = connection
                self.configurations[key] = config
                connection.onMessage = { [weak connection] message in
                    guard let connection else { return }
                    switch message["op"] as? String {
                    case "hello":
                        self.bootstrap(connection, configuration: config)
                        connection.send(["op": "request_icons"])
                    case "event" where message["event"] as? String == "icon_candidates":
                        var forwarded = message
                        forwarded["app"] = config.identifier
                        forwarded["profile"] = config.profile
                        BrainBridge.shared.send(forwarded)
                    case "event" where message["event"] as? String == "modsmith":
                        guard BrainBridge.shared.isConnected else {
                            connection.send(["op": "site_mod_status", "text": "Bowser is reconnecting. Your draft is kept; try again shortly."])
                            return
                        }
                        var forwarded = message
                        forwarded["app"] = ["id": config.identifier, "url": config.url.absoluteString, "profile": config.profile]
                        BrainBridge.shared.send(forwarded)
                    case "event" where message["event"] as? String == "site_mod_request":
                        guard let request = message["request"] as? String else { return }
                        guard BrainBridge.shared.isConnected else {
                            connection.send(["op": "site_mod_status", "text": "Bowser is reconnecting. Try again shortly."])
                            return
                        }
                        BrainBridge.shared.send(["op": "event", "event": "site_mod_request", "request": request,
                            "app": ["id": config.identifier, "url": config.url.absoluteString, "profile": config.profile]])
                    case "js_result":
                        guard let id = message["id"] as? Int, self.pending[id] == key else { return }
                        self.pending.removeValue(forKey: id)
                        BrainBridge.shared.send(message)
                    default: break
                    }
                }
                connection.onClose = {
                    self.connections.removeValue(forKey: key)
                    self.configurations.removeValue(forKey: key)
                    for id in self.pending.filter({ $0.value == key }).map(\.key) {
                        self.finishEval(id, error: "Saved app disconnected")
                    }
                }
                connection.startReading()
            }
        }
    }

    nonisolated static let storageExportScript = "return JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(k => [k,localStorage.getItem(k)])))"

    private func bootstrap(_ connection: SiteAppConnection, configuration: SiteAppConfiguration) {
        let profile = Profile.find(configuration.profile)
        profile.dataStore.httpCookieStore.getAllCookies { cookies in
            MainActor.assumeIsolated {
                let selected = cookies.filter { SiteAppRuntime.matches(cookieDomain: $0.domain, host: configuration.url.host ?? "") }
                let properties: [[String: String]] = selected.map { cookie in
                    var result: [String: String] = [:]
                    for (key, value) in cookie.properties ?? [:] {
                        if let date = value as? Date { result[key.rawValue] = String(date.timeIntervalSince1970) }
                        else { result[key.rawValue] = String(describing: value) }
                    }
                    return result
                }
                let send: (String?) -> Void = { storage in
                    connection.send(["op": "site_bootstrap", "cookies": properties,
                                     "scripts": EngineView.sharedScripts, "styles": EngineView.sharedStyles,
                                     "profile_scripts": Array(EngineView.content(for: profile.id).scripts.dropFirst(EngineView.sharedScripts.count)),
                                     "profile_styles": Array(EngineView.content(for: profile.id).styles.dropFirst(EngineView.sharedStyles.count)),
                                     "local_storage": storage ?? "{}"])
                }
                if let source = EngineView.live.values.first(where: {
                    $0.profileId == profile.id && $0.webView.url?.host == configuration.url.host
                        && $0.webView.url?.scheme == configuration.url.scheme && $0.webView.url?.port == configuration.url.port
                }) {
                    // Sites such as Discord delete the page world's storage
                    // accessor. The isolated world still has the native one.
                    source.webView.callAsyncJavaScript(Self.storageExportScript, arguments: [:], in: nil, in: .defaultClient) { result in
                        switch result {
                        case .success(let value): send(value as? String)
                        case .failure(let error):
                            NSLog("Bowser: site login storage export failed: %@", error.localizedDescription)
                            send(nil)
                        }
                    }
                } else { send(nil) }
            }
        }
    }

    private func finishEval(_ id: Int, error: String) {
        guard pending.removeValue(forKey: id) != nil else { return }
        BrainBridge.shared.send(["op": "js_result", "id": id, "ok": false, "value": error])
    }

    func route(_ message: [String: Any]) {
        let key = configurations.first { $0.value.identifier == message["app"] as? String }?.key
        guard let key, let connection = connections[key] else {
            if message["op"] as? String == "site_eval", let id = message["id"] as? Int {
                BrainBridge.shared.send(["op": "js_result", "id": id, "ok": false, "value": "Saved app is not running"])
            }
            return
        }
        if message["op"] as? String == "modsmith_state" {
            connection.send(message)
        } else if message["op"] as? String == "site_eval", let id = message["id"] as? Int {
            pending[id] = key
            connection.send(["op": "eval_js", "webview": 0, "id": id, "code": message["code"] ?? ""])
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.finishEval(id, error: "Saved app evaluation timed out") }
        } else {
            connection.send(["op": "site_mod_status", "text": message["text"] ?? ""])
        }
    }

    func requestIcons() {
        for connection in connections.values { connection.send(["op": "request_icons"]) }
    }

    func routeIcon(_ message: [String: Any]) {
        guard let key = configurations.first(where: { $0.value.identifier == message["app"] as? String })?.key else { return }
        connections[key]?.send(message)
    }

    func broadcastContent(_ message: [String: Any]) {
        for connection in connections.values { connection.send(message) }
    }
}

/// Framed JSON I/O is kept off the AppKit thread. A stalled app must never
/// stall the main browser. The lock protects closure/write against fd reuse.
final class SiteAppConnection: @unchecked Sendable {
    private var fd: Int32
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "bowser.site-app.writer")
    @MainActor var onMessage: (([String: Any]) -> Void)?
    @MainActor var onClose: (() -> Void)?
    private init(fd: Int32) { self.fd = fd }

    nonisolated static func connect(path: String, completion: @escaping @MainActor @Sendable (SiteAppConnection?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard fd >= 0, path.utf8.count < capacity else {
                if fd >= 0 { close(fd) }
                DispatchQueue.main.async { completion(nil) }; return
            }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { target in
                    path.withCString { source in _ = strcpy(target, source) }
                }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { close(fd); DispatchQueue.main.async { completion(nil) }; return }
            var enabled: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let connection = SiteAppConnection(fd: fd)
            DispatchQueue.main.async { completion(connection) }
        }
    }

    @MainActor func send(_ message: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: message) else { return }
        var size = UInt32(payload.count).bigEndian
        let frame = withUnsafeBytes(of: &size) { Data($0) } + payload
        writer.async {
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.fd >= 0 else { return }
            frame.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(self.fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard written > 0 else { return }
                    offset += written
                }
            }
        }
    }

    nonisolated func startReading() {
        DispatchQueue.global(qos: .utility).async {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(self.fd, &chunk, chunk.count)
                if n <= 0 { break }
                buffer.append(contentsOf: chunk.prefix(n))
                while buffer.count >= 4 {
                    let count = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                    guard count <= 64 * 1024 * 1024 else { self.finish(); return }
                    if buffer.count < count + 4 { break }
                    let data = buffer.subdata(in: 4..<(count + 4))
                    buffer.removeSubrange(0..<(count + 4))
                    DispatchQueue.main.async {
                        if let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            self.onMessage?(message)
                        }
                    }
                }
            }
            self.finish()
        }
    }

    nonisolated func disconnect() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    private func finish() {
        lock.lock()
        if fd >= 0 { close(fd); fd = -1 }
        lock.unlock()
        DispatchQueue.main.async {
            self.onClose?()
            self.onMessage = nil
            self.onClose = nil
        }
    }
}
