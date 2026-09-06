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
              let id = info["CFBundleIdentifier"] as? String, id.hasPrefix("com.gezim.bowser.site."),
              let app = info["BowserMainApp"] as? String else { return nil }
        return Self(url: url, profile: info["BowserProfile"] as? String ?? "default",
                    identifier: id, mainApp: URL(fileURLWithPath: app))
    }

    var home: URL {
        BowserPaths.home.appendingPathComponent("site-apps")
            .appendingPathComponent(identifier.replacingOccurrences(of: "com.gezim.bowser.site.", with: ""))
    }
}

@MainActor
final class SiteAppRuntime {
    static let shared = SiteAppRuntime()
    private var loaded = false
    private var seededStorage = false
    private weak var controller: BrowserWindowController?

    func start(_ configuration: SiteAppConfiguration, controller: BrowserWindowController) {
        self.controller = controller
        do {
            try FileManager.default.createDirectory(at: configuration.home, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(configuration).write(to: configuration.home.appendingPathComponent("app.json"), options: .atomic)
        } catch { NSLog("Bowser: site registration failed: %@", error.localizedDescription) }
        // Keep the main browser available to supply this profile's login and
        // mods. Do not activate it or steal focus from the saved app.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.gezim.bowser").isEmpty {
            let options = NSWorkspace.OpenConfiguration()
            options.activates = false
            NSWorkspace.shared.openApplication(at: configuration.mainApp, configuration: options) { _, error in
                if let error { NSLog("Bowser: main browser startup failed: %@", error.localizedDescription) }
            }
        }
        // The app's own persistent session remains usable if Bowser is down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.loadOnce() }
    }

    func bootstrap(_ message: [String: Any]) {
        guard let controller else { return }
        let scripts = message["scripts"] as? [String] ?? []
        let styles = message["styles"] as? [String] ?? []
        EngineView.rememberUserContent(scripts: scripts, styles: styles)
        controller.activeTab.applyUserContent(scripts: scripts, styles: styles, reload: false)
        guard !loaded else { return }
        loaded = true // only seed once; reconnect must never navigate the app
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
                connection.onMessage = { [weak connection] message in
                    if message["op"] as? String == "hello", let connection { self.bootstrap(connection, configuration: config) }
                }
                connection.onClose = { self.connections.removeValue(forKey: key) }
                connection.startReading()
            }
        }
    }

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
                                     "local_storage": storage ?? "{}"])
                }
                if let source = EngineView.live.values.first(where: {
                    $0.profileId == profile.id && $0.webView.url?.host == configuration.url.host
                        && $0.webView.url?.scheme == configuration.url.scheme && $0.webView.url?.port == configuration.url.port
                }) {
                    source.webView.evaluateJavaScript("JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(k => [k,localStorage.getItem(k)])))") { value, _ in
                        send(value as? String)
                    }
                } else { send(nil) }
            }
        }
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
