import XCTest
import AppKit
import SwiftUI
@testable import Bowser

final class SurfaceRootViewTests: XCTestCase {
    @MainActor func testMagnifyStripRendersInFloatingAndBareSurfaceRoots() throws {
        // Actual shape of the generated AOL launcher that previously hit
        // EnvironmentObject.error() on its first layout and killed the shell.
        let tree: [String: Any] = ["t": "vstack", "children": [
            ["t": "magnify_strip", "size": 88.0, "magnify": 1.25, "event": "aol_launch",
             "items": [["id": "welcome", "symbol": "globe", "title": "Welcome"],
                       ["id": "mail", "symbol": "envelope.fill", "title": "Mail"],
                       ["id": "search", "symbol": "magnifyingglass", "title": "Search"]]],
            ["t": "text", "text": "Welcome • Mail • Search"]
        ]]
        let cursor = CursorModel()
        cursor.point = CGPoint(x: 30, y: 120)
        let roots: [AnyView] = [
            AnyView(SurfaceRootView(surfaceId: "og_aol_launcher", title: "America Online", node: tree)),
            AnyView(SurfaceTreeView(surfaceId: "settings", node: tree)),
            AnyView(SurfaceTreeView(surfaceId: "edge_test", node: tree, cursor: cursor))
        ]
        for (index, root) in roots.enumerated() {
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertFalse(png.isEmpty)
            if let directory = ProcessInfo.processInfo.environment["BOWSER_SURFACE_RENDER"] {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("magnify-\(index).png"))
            }
        }
        // A surface render must not replace/reset the edge's supplied tracker.
        XCTAssertEqual(cursor.point, CGPoint(x: 30, y: 120))
    }
    @MainActor func testNotchProfileIdentityAtDeckWidth() throws {
        _ = NSApplication.shared
        let model = ProfileSettingsModel.shared
        let previous = model.profiles
        defer { model.replaceProfiles(previous) }
        let work = Profile(id: "work", name: "Work projects", tint: "#3e63dd", icon: nil, uuid: nil, character: "luigi")
        model.replaceProfiles([.defaultProfile, work])
        for profile in [Profile.defaultProfile, work] {
            let cursor = CursorModel()
            let items: [[String: Any]] = (1...6).map { ["id": String($0), "symbol": "globe", "active": $0 == 2, "title": "Tab \($0)"] }
            let tree: [String: Any] = ["t": "magnify_strip", "items": items, "size": 32.0, "spacing": 8.0, "profile_id": profile.id]
            let hosting = NSHostingView(rootView: SurfaceTreeView(surfaceId: "edge_dock", node: tree, cursor: cursor))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 48, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
            window.backgroundColor = .clear; window.isOpaque = false
            window.contentView = hosting; hosting.frame = NSRect(x: 0, y: 0, width: 48, height: 420)
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertFalse(png.isEmpty)
            if let directory = ProcessInfo.processInfo.environment["BOWSER_SURFACE_RENDER"] {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("profile-\(profile.id).png"))
            }
        }
    }

    @MainActor func testFloatingPanelCloseWorksWithoutBrainOrPanelsMod() async throws {
        _ = NSApplication.shared
        let id = "panel-close-test-" + UUID().uuidString
        let previous = Set(NSApp.windows.map(\.windowNumber))
        let tree: [String: Any] = ["t": "vstack", "children": [
            ["t": "text", "value": "Cobalt blue · silver bevels · gold accents"],
            ["t": "button", "label": "Quick-links toolbar: On", "event": "quick", "active": true, "symbol": "checkmark.square.fill"],
            ["t": "button", "label": "Left channel rail: On", "event": "rail", "active": true, "symbol": "checkmark.square.fill"],
            ["t": "button", "label": "Bottom status bar: On", "event": "status", "active": true, "symbol": "checkmark.square.fill"],
            ["t": "divider"],
            ["t": "text", "value": "Layout choices are saved across restarts."],
            ["t": "button", "label": "Back to Channels", "event": "back", "symbol": "arrow.left"]
        ]]
        SurfaceManager.shared.handle(["surface": "show", "id": id, "title": "Customize Classic AOL", "width": 320.0, "view": tree])
        let panel = try XCTUnwrap(NSApp.windows.first { !previous.contains($0.windowNumber) && $0 is NSPanel })
        defer { SurfaceManager.shared.handle(["surface": "close", "id": id]) }
        XCTAssertLessThan(panel.frame.height, 350)
        if let directory = ProcessInfo.processInfo.environment["BOWSER_PANEL_RENDER"] {
            let capture = try await NativeVerification.screenshot(panel)
            let png = try XCTUnwrap(Data(base64Encoded: capture["image"] as? String ?? ""))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("panel-fixed.png"))
        }
        try NativeVerification.click(panel, x: panel.frame.width - 23, y: 23)
        let down = try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown, until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true))
        NSApp.sendEvent(down)
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(up) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor func testPanelHeightFitsWrappedContentAtActualWidth() {
        let tree: [String: Any] = ["t": "vstack", "children": [
            ["t": "text", "value": String(repeating: "Layout choices persist across restarts. ", count: 5)]
        ]]
        let narrow = SurfaceManager.fittedHeight(surfaceId: "test", title: "Customize", node: tree, width: 240)
        let wide = SurfaceManager.fittedHeight(surfaceId: "test", title: "Customize", node: tree, width: 480)
        XCTAssertGreaterThan(narrow, wide)
        XCTAssertGreaterThan(wide, 60)
    }

}

final class PanelSizingTests: XCTestCase {
    func testContentFitBeatsTheModsGuessButIsCapped() {
        XCTAssertEqual(SurfaceManager.preferredWidth(requested: 260, natural: 372.2, remembered: nil), 373)
        XCTAssertEqual(SurfaceManager.preferredWidth(requested: 320, natural: 200, remembered: nil), 320)
        XCTAssertEqual(SurfaceManager.preferredWidth(requested: 260, natural: 900, remembered: nil), 480)
    }

    func testOwnersRememberedWidthWins() {
        XCTAssertEqual(SurfaceManager.preferredWidth(requested: 260, natural: 900, remembered: 410), 410)
        // a nonsense remembered width falls back to fit
        XCTAssertEqual(SurfaceManager.preferredWidth(requested: 260, natural: 300, remembered: 10), 300)
    }
}
