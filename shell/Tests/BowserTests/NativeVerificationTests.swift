import XCTest
import AppKit
import WebKit
@testable import Bowser

final class NativeVerificationTests: XCTestCase {
    @MainActor func testClicksRejectInvalidCoordinatesAndWebsiteViews() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertThrowsError(try NativeVerification.click(window, x: -1, y: 20))
        XCTAssertThrowsError(try NativeVerification.click(window, x: .nan, y: 20))
        XCTAssertThrowsError(try NativeVerification.click(window, x: 300, y: 20))
        window.contentView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertThrowsError(try NativeVerification.click(window, x: 100, y: 100))
    }

    @MainActor func testNativeClickDeliversButtonAction() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = NSButton(checkboxWithTitle: "Test", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 80, width: 120, height: 40)
        window.contentView?.addSubview(button)
        window.makeKeyAndOrderFront(nil)
        try NativeVerification.click(window, x: 50, y: 100)
        let event = try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown, until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true))
        NSApp.sendEvent(event)
        XCTAssertEqual(button.state, .on)
    }

    @MainActor func testCaptureRealWindowPixelsWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["BOWSER_NATIVE_CAPTURE_TEST"] == "1" else {
            throw XCTSkip("Requires screen capture permission and a visible desktop")
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .red
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let result = try await NativeVerification.screenshot(window)
        let data = try XCTUnwrap(Data(base64Encoded: result["image"] as? String ?? ""))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let pixel = try XCTUnwrap(bitmap.colorAt(x: 100, y: 100)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.9)
        XCTAssertGreaterThan(pixel.redComponent - pixel.blueComponent, 0.6) // Display color management can introduce small nonzero channels.
    }
}
