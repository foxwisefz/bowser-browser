import AppKit
import JavaScriptCore
import WebKit
import XCTest
@testable import Bowser

final class SiteAppTests: XCTestCase {
    func testCookieMatchingRespectsDomainBoundaries() {
        XCTAssertTrue(SiteAppRuntime.matches(cookieDomain: ".example.com", host: "app.example.com"))
        XCTAssertTrue(SiteAppRuntime.matches(cookieDomain: "example.com", host: "example.com"))
        XCTAssertFalse(SiteAppRuntime.matches(cookieDomain: "example.com", host: "notexample.com"))
        XCTAssertFalse(SiteAppRuntime.matches(cookieDomain: "example.com", host: "example.com.evil.test"))
    }

    func testCookieBootstrapPreservesHTTPOnlySecureAndExpiry() throws {
        let expires = Date().addingTimeInterval(3600)
        let cookie = try XCTUnwrap(SiteAppRuntime.cookie([
            "Name": "session", "Value": "fixture", "Domain": ".example.com", "Path": "/",
            "Secure": "TRUE", "HttpOnly": "TRUE", "Expires": String(expires.timeIntervalSince1970)
        ]))
        XCTAssertTrue(cookie.isSecure)
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertEqual(try XCTUnwrap(cookie.expiresDate).timeIntervalSince1970, expires.timeIntervalSince1970, accuracy: 1)
    }

    func testStorageSeedIsOriginScopedAndDoesNotOverwriteAppSession() throws {
        let script = try XCTUnwrap(SiteAppRuntime.storageSeedScript("{\"token\":\"parent session\",\"key\":\"value\"}", url: URL(string: "https://example.com")))
        let context = JSContext()!
        context.evaluateScript("var values={token:'existing app session'}; var location={origin:'https://other.test'}; var localStorage={getItem:k=>values[k]??null,setItem:(k,v)=>values[k]=v};")
        context.evaluateScript(script)
        XCTAssertEqual(context.evaluateScript("values.key")?.isUndefined, true)
        context.evaluateScript("location.origin='https://example.com';")
        context.evaluateScript(script)
        XCTAssertEqual(context.evaluateScript("values.token")?.toString(), "existing app session")
        XCTAssertEqual(context.evaluateScript("values.key")?.toString(), "value")
    }

    func testAppModFilesAreAppAndOriginScoped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = SiteAppConfiguration(url: URL(string: "https://example.com")!, profile: "default",
            identifier: "com.gezim.bowser.site.0123456789abcdef", mainApp: URL(fileURLWithPath: "/Applications/Bowser.app"))
        let directory = root.appendingPathComponent(config.identifier)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "globalThis.fixture='only this app';".write(to: directory.appendingPathComponent("test.js"), atomically: true, encoding: .utf8)
        try "globalThis.bad=true;".write(to: directory.appendingPathComponent("ignored.tmp"), atomically: true, encoding: .utf8)
        let scripts = SiteAppRuntime.modScripts(configuration: config, root: root)
        XCTAssertEqual(scripts.count, 1)
        let context = JSContext()!
        context.evaluateScript("var location={origin:'https://accounts.example.com'};")
        context.evaluateScript(scripts[0])
        XCTAssertTrue(context.evaluateScript("typeof fixture==='undefined'")!.toBool())
        context.evaluateScript("location.origin='https://example.com'")
        context.evaluateScript(scripts[0])
        XCTAssertEqual(context.evaluateScript("fixture")?.toString(), "only this app")
        let other = SiteAppConfiguration(url: config.url, profile: "work",
            identifier: "com.gezim.bowser.site.fedcba9876543210", mainApp: config.mainApp)
        XCTAssertTrue(SiteAppRuntime.modScripts(configuration: other, root: root).isEmpty)
    }

    @MainActor
    func testStorageExportWorksWhenPageDeletesItsAccessor() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        let loaded = expectation(description: "fixture loaded")
        let delegate = SiteTestNavigationDelegate(loaded)
        view.navigationDelegate = delegate
        view.loadHTMLString("<script>localStorage.setItem('session-fixture','present'); delete window.localStorage;</script>",
                            baseURL: URL(string: "https://login-fixture.invalid"))
        await fulfillment(of: [loaded], timeout: 10)
        let pageResult = try await view.evaluateJavaScript("typeof localStorage")
        XCTAssertEqual(pageResult as? String, "undefined")
        let storage = try await view.callAsyncJavaScript(SiteAppHub.storageExportScript, arguments: [:], in: nil, contentWorld: .defaultClient)
        let data = try XCTUnwrap((storage as? String)?.data(using: .utf8))
        let values = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(values["session-fixture"], "present")
    }

    /// Explicit integration gate: launches only a temporary fixture app with
    /// an isolated BOWSER_HOME, and quits only that process afterward.
    @MainActor
    func testSeparateApplicationIdentityAndReopen() async throws {
        guard ProcessInfo.processInfo.environment["BOWSER_RUN_SITE_APP_INTEGRATION"] == "1" else {
            throw XCTSkip("Set BOWSER_RUN_SITE_APP_INTEGRATION=1 for native app launch verification")
        }
        let root = URL(fileURLWithPath: "/tmp/bowser-site-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let browser = root.appendingPathComponent("Engine.app")
        let executable = browser.appendingPathComponent("Contents/MacOS/Bowser")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: shell.appendingPathComponent(".build/debug/Bowser"), to: executable)
        let preparationStart = ProcessInfo.processInfo.systemUptime
        let server = try SiteIconFixtureServer()
        defer { server.stop() }
        let bundle = try TabAppBundle.create(url: server.url, profile: "default",
                                             iconData: nil, directory: root, bowser: browser)
        print("Signed site app preparation: \((ProcessInfo.processInfo.systemUptime - preparationStart) * 1000)ms")
        let configuration = try XCTUnwrap(SiteAppConfiguration.parse(Bundle(url: bundle)!.infoDictionary!))
        let mainPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.gezim.bowser").map(\.processIdentifier))
        let options = NSWorkspace.OpenConfiguration()
        options.activates = false
        options.environment = ["BOWSER_HOME": root.appendingPathComponent("state").path]
        let running = try await NSWorkspace.shared.openApplication(at: bundle, configuration: options)
        defer { _ = running.terminate() }
        // Give AppKit startup time to register its normal Dock/app identity.
        for _ in 0..<30 {
            if running.isFinishedLaunching { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(running.isTerminated)
        XCTAssertEqual(running.bundleIdentifier, configuration.identifier)
        XCTAssertEqual(running.activationPolicy, .regular)
        XCTAssertFalse(mainPIDs.contains(running.processIdentifier))
        let connected = expectation(description: "site socket connected")
        let seeded = expectation(description: "profile cookie seeded before navigation")
        let controls = expectation(description: "app-specific controls")
        let mods = expectation(description: "app mod watcher applies private files")
        var inspectedCookies = false
        var iconJobStarted = false
        let workerRecovered = expectation(description: "Elixir recovers from icon worker SIGKILL")
        var channel: SiteAppConnection?
        var sentBootstrap = false
        let expectedSession = UUID().uuidString
        let delayedBootstrap = ProcessInfo.processInfo.environment["BOWSER_TEST_LATE_BOOTSTRAP"] == "1"
        let stateHome = root.appendingPathComponent("state/site-apps")
            .appendingPathComponent(configuration.identifier.replacingOccurrences(of: "com.gezim.bowser.site.", with: ""))
        let socketPath = stateHome.appendingPathComponent("brain.sock").path
        // LaunchServices can report finished before the listener's background
        // queue has bound its socket. Wait for readiness, not a fixed delay.
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socketPath) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "Site app listener did not start: \(socketPath)")
        SiteAppConnection.connect(path: socketPath) { connection in
            channel = connection
            XCTAssertNotNil(connection)
            connection?.onMessage = { message in
                if message["event"] as? String == "icon_candidates", !iconJobStarted {
                    iconJobStarted = true
                    do {
                        let input = root.appendingPathComponent("icon-request.json")
                        let output = root.appendingPathComponent("icon-response.json")
                        try JSONSerialization.data(withJSONObject: message).write(to: input)
                        Task { @MainActor in
                            let result = await Task.detached {
                                SiteIconTestBrain.run(shell: shell, root: root, input: input, output: output)
                            }.value
                            guard let result, let reply = try? JSONSerialization.jsonObject(with: result) as? [String: Any] else {
                                XCTFail("Isolated Elixir icon job failed; inspect fixture brain log")
                                return
                            }
                            XCTAssertEqual(reply["attempts"] as? Int, 2, "The first worker must crash and the second must recover")
                            XCTAssertFalse(running.isTerminated)
                            connection?.send(reply)
                            workerRecovered.fulfill()
                        }
                    } catch { XCTFail(error.localizedDescription) }
                }
                if message["op"] as? String == "hello" {
                    XCTAssertEqual((message["tabs"] as? [[String: Any]])?.count, 1)
                    Task { @MainActor in
                        if delayedBootstrap { try? await Task.sleep(for: .seconds(6)) }
                        sentBootstrap = true
                        connection?.send(["op": "site_bootstrap", "scripts": [], "styles": [], "cookies": [
                            ["Name": "site-test-session", "Value": expectedSession, "Domain": "127.0.0.1", "Path": "/", "HttpOnly": "TRUE"]
                        ]])
                    }
                }
                if sentBootstrap, message["event"] as? String == "load_status", message["status"] as? Int == 0 {
                    connection?.send(["op": "get_cookies", "url": "http://127.0.0.1:9/", "id": 731])
                }
                if message["op"] as? String == "cookies_result", message["id"] as? Int == 731, !inspectedCookies {
                    inspectedCookies = true
                    let cookies = message["cookies"] as? [[String: Any]] ?? []
                    XCTAssertTrue(cookies.contains { $0["name"] as? String == "site-test-session" && $0["value"] as? String == expectedSession && $0["http_only"] as? Bool == true })
                    seeded.fulfill()
                    connection?.send(["op": "site_app_info", "id": 733])
                }
                if message["op"] as? String == "site_app_info", message["id"] as? Int == 733 {
                    guard let icon = message["favicon"] as? String, icon.contains("tiles-v2") else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { connection?.send(["op": "site_app_info", "id": 733]) }
                        return
                    }
                    XCTAssertEqual((try? Data(contentsOf: URL(fileURLWithPath: icon))).flatMap(NSBitmapImageRep.init(data:))?.pixelsWide, 1024)
                    let titles = message["menu_titles"] as? [String] ?? []
                    XCTAssertFalse(titles.contains("New Tab"))
                    XCTAssertFalse(titles.contains("New Window In"))
                    XCTAssertFalse(titles.contains("Open Location"))
                    XCTAssertFalse(titles.contains("Settings…"))
                    XCTAssertEqual(message["page_top_inset"] as? Double, 0)
                    XCTAssertFalse(titles.contains("App Actions"))
                    XCTAssertFalse(titles.contains("Command Bar"))
                    XCTAssertTrue(titles.contains("Create Mod…"))
                    XCTAssertEqual(message["profile"] as? String, "default")
                    XCTAssertEqual(message["windows"] as? Int, 1)
                    XCTAssertTrue((message["actions"] as? [String] ?? []).contains("Create Mod…"))
                    controls.fulfill()
                    Task { @MainActor in
                        let directory = root.appendingPathComponent("state/app-mods").appendingPathComponent(configuration.identifier)
                        do {
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            try "globalThis.appFixture=true;".write(to: directory.appendingPathComponent("fixture.js"), atomically: true, encoding: .utf8)
                            try await Task.sleep(for: .milliseconds(1500))
                            connection?.send(["op": "set_user_content", "scripts": ["globalThis.inheritedFixture=true;"], "styles": [], "reload": false])
                            connection?.send(["op": "site_app_info", "id": 735])
                        } catch { XCTFail(error.localizedDescription) }
                    }
                }
                if message["op"] as? String == "site_app_info", message["id"] as? Int == 735 {
                    XCTAssertEqual(message["app_mod_count"] as? Int, 1)
                    mods.fulfill()
                }
            }
            connection?.startReading()
            connected.fulfill()
        }
        await fulfillment(of: [connected, seeded, controls, mods, workerRecovered], timeout: 25)
        // Keep the connection alive throughout the assertions and app quit.
        XCTAssertNotNil(channel)
        channel?.send(["op": "eval_js", "webview": 0, "id": 732,
                       "code": "setTimeout(()=>console.log('site disconnect test'),50); 'scheduled'"])
        channel?.disconnect()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(running.isTerminated, "The site survives its main-browser connection closing")
        let again = try await NSWorkspace.shared.openApplication(at: bundle, configuration: options)
        XCTAssertEqual(again.processIdentifier, running.processIdentifier)
        XCTAssertTrue(running.terminate())
        for _ in 0..<30 {
            if running.isTerminated { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(running.isTerminated)
        XCTAssertEqual(mainPIDs, Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.gezim.bowser").map(\.processIdentifier)))
    }
}

@MainActor
private final class SiteTestNavigationDelegate: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(_ loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}

/// Local HTTP fixture exercises the ACTUAL navigation -> favicon -> worker
/// path in a signed app, where Swift enforces executor checks more strictly.
private final class SiteIconFixtureServer: @unchecked Sendable {
    let fd: Int32
    let url: URL
    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        fd = listener
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(fd, 8) == 0 else { close(fd); throw CocoaError(.fileReadUnknown) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(listener, $0, &length) }
        }
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/")!
        DispatchQueue.global().async {
            let body = "<html><head><link rel='icon' type='image/svg+xml' href=\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='128' height='128'%3E%3Crect width='128' height='128' fill='purple'/%3E%3Crect x='40' y='40' width='48' height='48' fill='white'/%3E%3C/svg%3E\"></head><body>Icon fixture</body></html>"
            let response = Array("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { break }
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var input = [UInt8](repeating: 0, count: 8192)
                _ = read(client, &input, input.count)
                _ = response.withUnsafeBytes { write(client, $0.baseAddress!, $0.count) }
                close(client)
            }
        }
    }
    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
}

private enum SiteIconTestBrain {
    nonisolated static func run(shell: URL, root: URL, input: URL, output: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["elixir", shell.deletingLastPathComponent().appendingPathComponent("beam/test/support/icon_smoke.exs").path,
            input.path, output.path, root.appendingPathComponent("state").path,
            shell.appendingPathComponent(".build/debug/BowserIconWorker").path]
        let log = root.appendingPathComponent("icon-brain.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try? FileHandle(forWritingTo: log)
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return try Data(contentsOf: output)
        } catch { return nil }
    }
}
