import XCTest
import WebKit
@testable import Bowser

@MainActor
final class LocalFileTests: XCTestCase {
    func testLocalHTMLLoadsSiblingScriptAndStylesWithFragment() async throws {
        try await checkLoad(rawPath: false)
    }

    func testDirectNavigationInfersFileSchemeForAbsolutePath() async throws {
        try await checkLoad(rawPath: true)
    }

    private func checkLoad(rawPath: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "body { color: rgb(12, 34, 56); }".write(to: directory.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try "window.fixtureReady = true;".write(to: directory.appendingPathComponent("script.js"), atomically: true, encoding: .utf8)
        try "<html><head><link rel='stylesheet' href='style.css'></head><body>Local<script src='script.js'></script></body></html>".write(to: directory.appendingPathComponent("My Page#1.html"), atomically: true, encoding: .utf8)
        let view = EngineView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        defer { view.tearDown() }
        let file = directory.appendingPathComponent("My Page#1.html")
        let input = rawPath ? file.path : file.absoluteString + "#section"
        view.load(urlString: input)
        var ready = false
        for _ in 0..<100 {
            if (try? await view.webView.evaluateJavaScript("window.fixtureReady === true && document.readyState === 'complete'")) as? Bool == true {
                ready = true; break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(ready, "Sibling JavaScript should load through file read access")
        let color = try await view.webView.evaluateJavaScript("getComputedStyle(document.body).color") as? String
        XCTAssertEqual(color, "rgb(12, 34, 56)")
        let fragment = try await view.webView.evaluateJavaScript("location.hash") as? String
        XCTAssertEqual(fragment, rawPath ? "" : "#section")
        XCTAssertTrue(view.webView.url?.isFileURL == true)
    }
}
