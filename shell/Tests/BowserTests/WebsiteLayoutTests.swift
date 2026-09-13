import AppKit
import XCTest
@testable import Bowser

final class WebsiteLayoutTests: XCTestCase {
    private func leaf(_ id: UInt64, weight: Double = 1, width: Double = 0, height: Double = 0) -> [String: Any] {
        ["type": "webview", "webview": id, "weight": weight, "min_width": width, "min_height": height]
    }
    private func row(_ children: [[String: Any]], resizable: Bool = true) -> [String: Any] {
        ["type": "row", "children": children, "resizable": resizable]
    }
    private func column(_ children: [[String: Any]]) -> [String: Any] { ["type": "column", "children": children] }

    @MainActor func testNestedLayoutsHaveNoFlatPaneLimitAndRoundTripDraggedSizes() throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        for _ in 0..<5 { host.openTab(activate: false) }
        let views = host.tabs
        let ids = views.map(\.webviewId)
        let tree = row([leaf(ids[0], weight: 2), column([leaf(ids[1]),
            row([leaf(ids[2]), leaf(ids[3]), leaf(ids[4]), leaf(ids[5])])])])
        try host.applyWebsiteLayout(tree: tree)
        let layout = try XCTUnwrap(host.websiteLayout)
        let outer = try XCTUnwrap(layout.content as? WebsiteSplit)
        let inner = try XCTUnwrap(outer.panes[1] as? WebsiteSplit)
        XCTAssertEqual(layout.ids, ids)
        XCTAssertTrue(outer.isVertical)
        XCTAssertFalse(inner.isVertical)
        for view in views { XCTAssertTrue(view.isDescendant(of: layout)); XCTAssertGreaterThan(view.frame.width, 0) }
        outer.setPosition(outer.bounds.width * 0.55, ofDividerAt: 0)
        inner.setPosition(inner.bounds.height * 0.7, ofDividerAt: 0)
        let outerRatio = outer.fractions[0], innerRatio = inner.fractions[0]
        layout.setFrameSize(NSSize(width: 1000, height: 700))
        XCTAssertEqual(outer.fractions[0], outerRatio, accuracy: 0.01)
        XCTAssertEqual(inner.fractions[0], innerRatio, accuracy: 0.01)
        let snapshot = layout.tree
        try host.applyWebsiteLayout(tree: snapshot)
        let rebuilt = try XCTUnwrap(host.websiteLayout?.content as? WebsiteSplit)
        XCTAssertEqual(rebuilt.fractions[0], outerRatio, accuracy: 0.01)
        XCTAssertEqual((rebuilt.panes[1] as? WebsiteSplit)?.fractions[0] ?? 0, innerRatio, accuracy: 0.01)
        XCTAssertTrue(host.tabs[4] === views[4])
    }

    @MainActor func testContainerReplacementRetainsViewsWeightsAndLeafRoots() throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        let first = host.activeTab!, second = host.openTab(activate: false)
        try host.applyWebsiteLayout(tree: row([leaf(first.webviewId, weight: 3), leaf(second.webviewId)]))
        let layout = try XCTUnwrap(host.websiteLayout)
        let original = layout.content
        let ratio = first.frame.width / layout.bounds.width
        layout.replaceContainers()
        XCTAssertFalse(layout.content === original)
        XCTAssertTrue(first.isDescendant(of: layout))
        XCTAssertTrue(second.isDescendant(of: layout))
        XCTAssertEqual(first.frame.width / layout.bounds.width, ratio, accuracy: 0.01)
        XCTAssertTrue(host.tabs[0] === first)
        try host.applyWebsiteLayout(tree: leaf(first.webviewId))
        let single = try XCTUnwrap(host.websiteLayout)
        single.replaceContainers()
        XCTAssertTrue(single.content === first)
        XCTAssertTrue(first.isDescendant(of: single))
    }

    @MainActor func testConstraintsAndFixedDividers() throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        let first = host.activeTab!, second = host.openTab(activate: false)
        try host.applyWebsiteLayout(tree: row([leaf(first.webviewId, weight: 0.001, width: 240), leaf(second.webviewId)], resizable: false))
        let split = try XCTUnwrap(host.websiteLayout?.content as? WebsiteSplit)
        XCTAssertGreaterThanOrEqual(first.frame.width, 239)
        let before = first.frame
        split.setPosition(500, ofDividerAt: 0)
        XCTAssertEqual(first.frame, before)
        split.setFrameSize(NSSize(width: 100, height: 80))
        XCTAssertGreaterThanOrEqual(first.frame.width, 0)
        XCTAssertGreaterThanOrEqual(second.frame.width, 0)
        XCTAssertLessThanOrEqual(second.frame.maxX, 100.01)
        let allocated = WebsiteSplit.allocate(available: 100, weights: [Double.greatestFiniteMagnitude, 1], minima: [0, 20])
        XCTAssertEqual(allocated[0], 80, accuracy: 0.001)
        XCTAssertEqual(allocated[1], 20, accuracy: 0.001)
    }

    @MainActor func testFocusAndPruningKeepRemainingPagesAlive() throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        let first = host.activeTab!, second = host.openTab(activate: false), third = host.openTab(activate: false)
        try host.applyWebsiteLayout(tree: row([leaf(first.webviewId), column([leaf(second.webviewId), leaf(third.webviewId)])]))
        // A recent local launch frame may cover the window; this test exercises
        // page focus after that startup overlay has gone.
        host.window?.contentView?.subviews.compactMap { $0 as? ResurrectOverlayView }.forEach { $0.removeFromSuperview() }
        let point = third.convert(NSPoint(x: third.bounds.midX, y: third.bounds.midY), to: nil)
        host.focusPane(at: point)
        XCTAssertTrue(host.activeTab === third)
        host.activate(first)
        let root = try XCTUnwrap(host.window?.contentView)
        let overlay = NSView(frame: root.convert(third.bounds, from: third))
        root.addSubview(overlay)
        host.focusPane(at: point)
        XCTAssertTrue(host.activeTab === first)
        overlay.removeFromSuperview()
        host.closeTab(second)
        XCTAssertEqual(host.websiteLayout?.ids, [first.webviewId, third.webviewId])
        XCTAssertTrue(host.activeTab === first)
        XCTAssertNotNil(third.superview)
        XCTAssertNil(EngineView.live[second.webviewId])
        host.closeTab(first)
        XCTAssertEqual(host.websiteLayout?.ids, [third.webviewId])
        XCTAssertTrue(host.activeTab === third)
        host.resetWebsiteLayout()
        XCTAssertNil(host.websiteLayout)
        XCTAssertNotNil(third.superview)
        XCTAssertEqual(host.tabs.count, 1)
    }

    @MainActor func testWarmupAndOutsideActivation() async throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        let first = host.activeTab!, second = host.openTab(activate: false)
        host.warmTab(id: second.webviewId, ms: 1000)
        try host.applyWebsiteLayout(tree: column([row([leaf(first.webviewId), leaf(second.webviewId)])]))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(second.isDescendant(of: try XCTUnwrap(host.websiteLayout)))
        let background = host.openTab(activate: false)
        host.closeTab(background)
        XCTAssertNotNil(host.websiteLayout)
        let outside = host.openTab()
        XCTAssertNil(host.websiteLayout)
        XCTAssertTrue(host.activeTab === outside)
        XCTAssertNil(first.superview)
        XCTAssertNil(second.superview)
    }

    @MainActor func testInvalidTreesAreAtomicAndCannotStealViews() throws {
        let host = BrowserWindowController(profile: .defaultProfile), other = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close(); other.window?.close() }
        let first = host.activeTab!, second = host.openTab(activate: false)
        try host.applyWebsiteLayout(tree: row([leaf(first.webviewId), leaf(second.webviewId)]))
        let layout = host.websiteLayout
        var deep = leaf(first.webviewId)
        for _ in 0..<16 { deep = row([deep]) }
        let invalid: [[String: Any]] = [row([]), row([leaf(first.webviewId), leaf(first.webviewId)]),
            row([leaf(first.webviewId), leaf(other.activeTab.webviewId)]), leaf(first.webviewId, weight: 0),
            leaf(first.webviewId, weight: .nan), leaf(first.webviewId, width: -1),
            ["type": "webview", "webview": true], deep,
            row((1...256).map { leaf(UInt64($0)) }), ["type": "grid", "children": [leaf(first.webviewId)]]]
        for tree in invalid {
            XCTAssertThrowsError(try host.applyWebsiteLayout(tree: tree))
            XCTAssertTrue(host.websiteLayout === layout)
        }
        XCTAssertThrowsError(try host.websiteLayoutCommand(["action": "reset", "profile": "other-profile"]))
        XCTAssertTrue(host.websiteLayout === layout)
    }

    @MainActor func testLeafRootAndCommandProtocol() throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        let first = host.activeTab!
        XCTAssertThrowsError(try host.websiteLayoutCommand(["action": "create_tab", "profile": "default", "url": "file:///etc/passwd"]))
        let created = try host.websiteLayoutCommand(["action": "create_tab", "profile": "default", "url": "http://127.0.0.1:9/"])
        let id = try XCTUnwrap(created["created"] as? UInt64)
        let state = try host.websiteLayoutCommand(["action": "set", "profile": "default", "tree": leaf(id)])
        XCTAssertEqual(state["panes"] as? [UInt64], [id])
        XCTAssertEqual((state["tree"] as? [String: Any])?["type"] as? String, "webview")
        host.closeTab(id: id)
        XCTAssertTrue(host.activeTab === first)
        XCTAssertNotNil(first.superview)
        XCTAssertNil(host.websiteLayout)
    }
}
