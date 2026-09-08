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
    /// The ✕ must be indistinguishable from the View-menu toggle for the
    /// same panel — that id is what the panels mod suppresses on.
    func testCloseClickIdMatchesViewMenuToggleId() {
        XCTAssertEqual(SurfaceRootView.closeClickId(for: "modsmith"), "panel:modsmith")
        XCTAssertEqual(SurfaceRootView.closeClickId(for: "mods"), "panel:mods")
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
