import AppKit
import ScreenCaptureKit
import WebKit

@MainActor
enum NativeVerification {
    static func screenshot(_ window: NSWindow) async throws -> [String: Any] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw NSError(domain: "Bowser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Browser window is not visible for capture"])
        }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Bowser", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode screenshot"])
        }
        return ["image": png.base64EncodedString(), "mimeType": "image/png",
                "width": image.width, "height": image.height, "window": window.windowNumber,
                "coordinates": "Window points from top-left; screenshot uses one pixel per point"]
    }

    static func click(_ window: NSWindow, x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < window.frame.width, y < window.frame.height,
              let root = window.contentView else {
            throw NSError(domain: "Bowser", code: 3, userInfo: [NSLocalizedDescriptionKey: "Click is outside the browser content"])
        }
        let point = NSPoint(x: x, y: window.frame.height - y)
        let local = root.convert(point, from: nil)
        guard root.bounds.contains(local), let hit = root.hitTest(local) else {
            throw NSError(domain: "Bowser", code: 4, userInfo: [NSLocalizedDescriptionKey: "No native control at this point"])
        }
        var ancestor: NSView? = hit
        while let view = ancestor {
            if view is WKWebView {
                throw NSError(domain: "Bowser", code: 5, userInfo: [NSLocalizedDescriptionKey: "Use page tools for website interactions"])
            }
            ancestor = view.superview
        }
        window.makeKeyAndOrderFront(nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }
}
