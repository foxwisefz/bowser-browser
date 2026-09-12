import AppKit
import WebKit
import XCTest
@testable import Bowser

@MainActor final class PictureInPictureTests: XCTestCase {
    func testRealVideoEntersExitsAndSurvivesDetachingTab() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let engine = EngineView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        let window = NSWindow(contentRect: engine.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = engine
        window.makeKeyAndOrderFront(nil)
        defer { engine.tearDown(); window.close() }
        let video = "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAQjbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAB9AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAA010cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAB9AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAKAAAABaAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAfQAAAIAAABAAAAAALFbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAAUABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAACcG1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAjBzdGJsAAAAwHN0c2QAAAAAAAAAAQAAALBhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAKAAWgBIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDAgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAANmF2Y0MBZAAK/+EAGWdkAAqs2UKN+TARAAADAAEAAAMAFA8SJZYBAAZo6+PLIsD9+PgAAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAEEAAAAAAAAAAGHN0dHMAAAAAAAAAAQAAABQAAAQAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAACoY3R0cwAAAAAAAAATAAAAAQAACAAAAAABAAAUAAAAAAEAAAgAAAAAAQAAAAAAAAABAAAEAAAAAAEAABQAAAAAAQAACAAAAAABAAAAAAAAAAEAAAQAAAAAAQAAFAAAAAABAAAIAAAAAAEAAAAAAAAAAQAABAAAAAABAAAUAAAAAAEAAAgAAAAAAQAAAAAAAAABAAAEAAAAAAEAABAAAAAAAgAABAAAAAAcc3RzYwAAAAAAAAABAAAAAQAAABQAAAABAAAAZHN0c3oAAAAAAAAAAAAAABQAAALrAAAAEAAAAA0AAAANAAAADQAAABYAAAAPAAAADQAAAA0AAAAWAAAADwAAAA0AAAANAAAAFgAAAA8AAAANAAAADQAAABUAAAAPAAAADQAAABRzdGNvAAAAAAAAAAEAAARTAAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDAAAAAIZnJlZQAABBhtZGF0AAACrgYF//+q3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTMgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MzoweDExMyBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MSBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTMgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0zIGJfcHlyYW1pZD0yIGJfYWRhcHQ9MSBiX2JpYXM9MCBkaXJlY3Q9MSB3ZWlnaHRiPTEgb3Blbl9nb3A9MCB3ZWlnaHRwPTIga2V5aW50PTI1MCBrZXlpbnRfbWluPTEwIHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAANWWIhAAR//7n4/wKbXzEcTp2GPr31tdyoujXh1cYhTyC6u2OqN+Hdwy1OBQfXYESAAXsGvrxAAAADEGaJGxBH/61KoAeMAAAAAlBnkJ4h38AaEEAAAAJAZ5hdEN/AJSAAAAACQGeY2pDfwCUgQAAABJBmmhJqEFomUwII//+tSqAHjEAAAALQZ6GRREsO/8AaEEAAAAJAZ6ldEN/AJSBAAAACQGep2pDfwCUgAAAABJBmqxJqEFsmUwIIf/+qlUAPGAAAAALQZ7KRRUsO/8AaEEAAAAJAZ7pdEN/AJSAAAAACQGe62pDfwCUgAAAABJBmvBJqEFsmUwIf//+qZYA5oEAAAALQZ8ORRUsO/8AaEEAAAAJAZ8tdEN/AJSBAAAACQGfL2pDfwCUgAAAABFBmzNJqEFsmUwIb//+p4QBxwAAAAtBn1FFFSw3/wCUgQAAAAkBn3JqQ38AlIA="
        engine.webView.loadHTMLString("<video id='v' controls muted autoplay loop src='data:video/mp4;base64,\(video)'></video>", baseURL: URL(string: "https://pip.fixture"))
        for _ in 0..<100 {
            if (try? await engine.webView.evaluateJavaScript("document.querySelector('video')?.readyState")) as? Int ?? 0 >= 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let supported = try await engine.webView.evaluateJavaScript("document.querySelector('video').webkitSupportsPresentationMode('picture-in-picture')")
        XCTAssertEqual(supported as? Bool, true)
        let entered = try await engine.webView.evaluateJavaScript(PictureInPicture.toggleScript)
        XCTAssertEqual(entered as? String, "entering")
        for _ in 0..<60 {
            if (try? await engine.webView.evaluateJavaScript("document.querySelector('video').webkitPresentationMode")) as? String == "picture-in-picture" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let mode = try await engine.webView.evaluateJavaScript("document.querySelector('video').webkitPresentationMode")
        XCTAssertEqual(mode as? String, "picture-in-picture")
        // WebKit updates presentationMode before its window animation completes.
        try await Task.sleep(for: .seconds(1))
        engine.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(250))
        let detached = try await engine.webView.evaluateJavaScript("document.querySelector('video').webkitPresentationMode")
        XCTAssertEqual(detached as? String, "picture-in-picture")
        window.contentView = engine
        try await Task.sleep(for: .milliseconds(250))
        let exited = try await engine.webView.evaluateJavaScript(PictureInPicture.toggleScript)
        XCTAssertEqual(exited as? String, "exiting")
        for _ in 0..<60 {
            if (try? await engine.webView.evaluateJavaScript("document.querySelector('video').webkitPresentationMode")) as? String == "inline" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let inline = try await engine.webView.evaluateJavaScript("document.querySelector('video').webkitPresentationMode")
        XCTAssertEqual(inline as? String, "inline")
    }

    func testPageWithoutVideoReportsUnavailable() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let engine = EngineView(frame: .zero, configuration: config)
        defer { engine.tearDown() }
        let result = try await engine.webView.evaluateJavaScript(PictureInPicture.toggleScript)
        XCTAssertEqual(result as? String, "unavailable")
    }
}
