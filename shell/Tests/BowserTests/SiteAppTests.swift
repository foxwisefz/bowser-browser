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
        let bundle = try TabAppBundle.create(url: URL(string: "http://127.0.0.1:9/")!, profile: "default",
                                             icon: nil, directory: root, bowser: browser)
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
        var channel: SiteAppConnection?
        var sentBootstrap = false
        let expectedSession = UUID().uuidString
        let delayedBootstrap = ProcessInfo.processInfo.environment["BOWSER_TEST_LATE_BOOTSTRAP"] == "1"
        let stateHome = root.appendingPathComponent("state/site-apps")
            .appendingPathComponent(configuration.identifier.replacingOccurrences(of: "com.gezim.bowser.site.", with: ""))
        SiteAppConnection.connect(path: stateHome.appendingPathComponent("brain.sock").path) { connection in
            channel = connection
            XCTAssertNotNil(connection)
            connection?.onMessage = { message in
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
                if message["op"] as? String == "cookies_result", message["id"] as? Int == 731 {
                    let cookies = message["cookies"] as? [[String: Any]] ?? []
                    XCTAssertTrue(cookies.contains { $0["name"] as? String == "site-test-session" && $0["value"] as? String == expectedSession && $0["http_only"] as? Bool == true })
                    seeded.fulfill()
                }
            }
            connection?.startReading()
            connected.fulfill()
        }
        await fulfillment(of: [connected, seeded], timeout: 10)
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
