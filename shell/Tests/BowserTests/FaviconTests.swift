import AppKit
import XCTest
import WebKit
@testable import Bowser

final class FaviconTests: XCTestCase {
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
        let base64 = try XCTUnwrap((value as? [[String: Any]])?.first?["png"] as? String)
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 512)
        let pixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
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
        let data = try XCTUnwrap(Data(base64Encoded: XCTUnwrap((value as? [[String: Any]])?.first?["png"] as? String)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let pixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(pixel.greenComponent, 0.9)
        XCTAssertGreaterThan(pixel.alphaComponent, 0.9)
    }

    @MainActor
    func testManifestDiscoveryAndOriginalIconAvoidNotificationBadge() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        let loaded = expectation(description: "metadata fixture loaded")
        let delegate = FaviconPageDelegate(loaded: loaded)
        webView.navigationDelegate = delegate
        webView.loadHTMLString("<head></head><body></body>", baseURL: URL(string: "https://fixture.invalid/app/"))
        await fulfillment(of: [loaded], timeout: 10)
        let setup = """
        const raster = (size, color) => {
          const c=document.createElement('canvas');c.width=size;c.height=size;
          const ctx=c.getContext('2d');ctx.fillStyle=color;ctx.fillRect(0,0,size,size);return c.toDataURL();
        };
        const badge = raster(512,'red'), clean = raster(256,'blue'), large = raster(512,'lime');
        document.head.querySelectorAll('link').forEach(l=>l.remove());
        const icon=document.createElement('link');icon.rel='icon';icon.href=badge;document.head.appendChild(icon);
        if (withManifest) { const m=document.createElement('link');m.rel='manifest';m.href='/manifest.json';document.head.appendChild(m); }
        const fetch = async url => ({ok:true, url:url.endsWith('manifest.json') ? 'https://fixture.invalid/assets/manifest.json' : url,
          text:async()=>url.endsWith('manifest.json') ? JSON.stringify({icons:[{src:'icon.png',sizes:'512x512'}]}) : '<link rel="icon" href="/clean.png">'});
        const Image = function() {
          const image=new window.Image();
          const setter=Object.getOwnPropertyDescriptor(window.HTMLImageElement.prototype,'src').set;
          Object.defineProperty(image,'src',{set:url=>setter.call(image, url==='https://fixture.invalid/assets/icon.png' ? large : url==='https://fixture.invalid/clean.png' ? clean : url)});
          return image;
        };
        """
        for withManifest in [false, true] {
            let result = try await webView.callAsyncJavaScript(setup + EngineView.pageFaviconProbe,
                arguments: ["withManifest": withManifest], in: nil, contentWorld: .defaultClient)
            let data = try XCTUnwrap(Data(base64Encoded: XCTUnwrap((result as? [[String: Any]])?.max(by: { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) })?["png"] as? String)))
            let image = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(image.pixelsWide, withManifest ? 512 : 256)
            let pixel = try XCTUnwrap(image.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
            XCTAssertLessThan(pixel.redComponent, 0.05, "The larger live notification badge must never win")
            if withManifest { XCTAssertGreaterThan(pixel.greenComponent, 0.95) }
            else { XCTAssertGreaterThan(pixel.blueComponent, 0.95) }
        }
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
