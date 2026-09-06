import AppKit
import XCTest
import JavaScriptCore
import WebKit
@testable import Bowser

final class FaviconTests: XCTestCase {
    func testChangedIconUsesDifferentImageCacheEntry() {
        let first = Data("first page icon".utf8)
        let second = Data("second page icon".utf8)
        XCTAssertNotEqual(EngineView.faviconFilename(for: first), EngineView.faviconFilename(for: second))
        XCTAssertEqual(EngineView.faviconFilename(for: first), EngineView.faviconFilename(for: first))
    }

    func testPrefersPNGOverLeadingInlineSVG() {
        let context = JSContext()!
        context.evaluateScript("""
        var location = {origin: "https://example.com"};
        var links = [
          {type: "image/svg+xml", href: "data:image/svg+xml,svg"},
          {type: "image/png", href: "https://example.com/icon.png?vsn=1"}
        ];
        var document = {querySelectorAll: function () { return links; }};
        """)
        XCTAssertEqual(context.evaluateScript(EngineView.faviconProbe)?.toString(),
                       "https://example.com/icon.png?vsn=1")
        context.evaluateScript("links = [];")
        XCTAssertEqual(context.evaluateScript(EngineView.faviconProbe)?.toString(),
                       "https://example.com/favicon.ico")
    }

    @MainActor
    func testInlineSVGProducesNativePNGDespiteBrokenRasterAlternative() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        let loaded = expectation(description: "page loaded")
        let delegate = FaviconPageDelegate(loaded: loaded)
        webView.navigationDelegate = delegate
        webView.loadHTMLString("""
        <html><head>
        <link rel="icon" type="image/svg+xml"
          href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='32' height='32'%3E%3Crect width='32' height='32' fill='red'/%3E%3C/svg%3E">
        <link rel="icon" type="image/png" href="https://invalid.invalid/missing.png">
        </head><body></body></html>
        """, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        let value = try await webView.callAsyncJavaScript(
            EngineView.pageFaviconProbe, arguments: [:], in: nil, contentWorld: .defaultClient)
        let base64 = try XCTUnwrap(value as? String)
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 64)
        let pixel = try XCTUnwrap(bitmap.colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.9)
        XCTAssertGreaterThan(pixel.alphaComponent, 0.9)
    }

    @MainActor
    func testBrokenFirstCandidateFallsBackToRasterInWebKit() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        let loaded = expectation(description: "raster page loaded")
        let delegate = FaviconPageDelegate(loaded: loaded)
        webView.navigationDelegate = delegate
        webView.loadHTMLString("""
        <html><head><link rel="icon" href="data:image/png;base64,invalid"></head>
        <body><script>
        var c = document.createElement('canvas'); c.width = 32; c.height = 32;
        var ctx = c.getContext('2d'); ctx.fillStyle = '#00ff00'; ctx.fillRect(0, 0, 32, 32);
        var icon = document.createElement('link'); icon.rel = 'icon';
        icon.type = 'image/png'; icon.href = c.toDataURL('image/png'); document.head.appendChild(icon);
        </script></body></html>
        """, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        let value = try await webView.callAsyncJavaScript(
            EngineView.pageFaviconProbe, arguments: [:], in: nil, contentWorld: .defaultClient)
        let data = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(value as? String)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let pixel = try XCTUnwrap(bitmap.colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(pixel.greenComponent, 0.9)
        XCTAssertGreaterThan(pixel.alphaComponent, 0.9)
    }

    @MainActor
    func testCommittedNavigationClearsPreviousIcon() {
        let view = EngineView(frame: .zero, configuration: nil)
        defer { view.tearDown() }
        view.webView(view.webView, didCommit: nil)
        XCTAssertEqual(view.faviconPath, "")
        XCTAssertNil(ImageCache.load(view.faviconPath!))
    }
}

@MainActor
private final class FaviconPageDelegate: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }
}
