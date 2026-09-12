import AppKit
import XCTest
@testable import Bowser

final class WebsiteLayoutTests: XCTestCase {
    @MainActor func testLiveViewsResizeAndPaneFocusPreservesLayout() throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        let left = try XCTUnwrap(host.activeTab)
        let right = host.openTab(activate: false)
        try host.applyWebsiteLayout(ids: [left.webviewId, right.webviewId], axis: "horizontal", weights: [0.4, 0.6])
        let layout = try XCTUnwrap(host.websiteLayout)
        XCTAssertTrue(left.superview === layout)
        XCTAssertTrue(right.superview === layout)
        XCTAssertTrue(layout.isVertical)
        XCTAssertEqual(layout.fractions[0], 0.4, accuracy: 0.01)
        layout.setPosition(layout.bounds.width * 0.6, ofDividerAt: 0)
        let dragged = layout.fractions[0]
        XCTAssertGreaterThan(dragged, 0.55)
        layout.setFrameSize(NSSize(width: 900, height: 700))
        XCTAssertEqual(layout.fractions[0], dragged, accuracy: 0.01)
        XCTAssertGreaterThan(right.frame.width, 0)
        let point = layout.convert(NSPoint(x: right.frame.midX, y: right.frame.midY), to: nil)
        host.focusPane(at: point)
        XCTAssertTrue(host.activeTab === right)
        XCTAssertTrue(host.websiteLayout === layout)
        host.activate(left)
        XCTAssertTrue(right.superview === layout)
        let root = try XCTUnwrap(host.window?.contentView)
        let overlay = NSView(frame: root.convert(right.bounds, from: right))
        root.addSubview(overlay)
        host.focusPane(at: point)
        XCTAssertTrue(host.activeTab === left)
        overlay.removeFromSuperview()
        host.resetWebsiteLayout()
        XCTAssertNil(host.websiteLayout)
        XCTAssertTrue(host.activeTab === left)
        XCTAssertNotNil(left.superview)
        XCTAssertNil(right.superview)
        XCTAssertEqual(host.tabs.count, 2)
    }

    @MainActor func testWarmupCannotDetachAVisiblePane() async throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        let first = try XCTUnwrap(host.activeTab)
        let second = host.openTab(activate: false)
        host.warmTab(id: second.webviewId, ms: 1000)
        try host.applyWebsiteLayout(ids: [first.webviewId, second.webviewId], axis: "horizontal", weights: [1, 1])
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(second.superview === host.websiteLayout)
        XCTAssertTrue(host.activeTab === first)
        let background = host.openTab(activate: false)
        host.closeTab(background)
        XCTAssertNotNil(host.websiteLayout)
    }

    @MainActor func testColumnAndLifecycle() throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        let first = try XCTUnwrap(host.activeTab)
        let second = host.openTab(activate: false)
        let third = host.openTab(activate: false)
        try host.applyWebsiteLayout(ids: [first.webviewId, second.webviewId, third.webviewId], axis: "vertical", weights: [1, 1, 1])
        let layout = try XCTUnwrap(host.websiteLayout)
        XCTAssertFalse(layout.isVertical)
        XCTAssertLessThan(first.frame.minY, second.frame.minY)
        XCTAssertLessThan(second.frame.minY, third.frame.minY)
        host.closeTab(second)
        XCTAssertNil(host.websiteLayout)
        XCTAssertTrue(host.activeTab === first)
        XCTAssertEqual(host.tabs.count, 2)
        XCTAssertNil(EngineView.live[second.webviewId])
        try host.applyWebsiteLayout(ids: [first.webviewId, third.webviewId], axis: "horizontal", weights: [1, 1])
        let outside = host.openTab()
        XCTAssertNil(host.websiteLayout)
        XCTAssertTrue(host.activeTab === outside)
        XCTAssertNil(first.superview)
        XCTAssertNil(third.superview)
    }

    @MainActor func testInvalidLayoutsAreAtomicAndRejectCrossWindowTabs() throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        let other = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close(); other.window?.close() }
        let first = try XCTUnwrap(host.activeTab)
        let second = host.openTab(activate: false)
        try host.applyWebsiteLayout(ids: [first.webviewId, second.webviewId], axis: "horizontal", weights: [1, 1])
        let layout = host.websiteLayout
        for ids in [[first.webviewId], [first.webviewId, first.webviewId], [first.webviewId, other.activeTab.webviewId]] {
            XCTAssertThrowsError(try host.applyWebsiteLayout(ids: ids, axis: "horizontal", weights: ids.map { _ in 1 }))
            XCTAssertTrue(host.websiteLayout === layout)
        }
        for weights in [[0, 1], [Double.nan, 1], [Double.infinity, 1], [1]] {
            XCTAssertThrowsError(try host.applyWebsiteLayout(ids: [first.webviewId, second.webviewId], axis: "horizontal", weights: weights))
        }
        XCTAssertThrowsError(try host.websiteLayoutCommand(["action": "reset", "profile": "other-profile"]))
        XCTAssertTrue(host.websiteLayout === layout)
    }

    @MainActor func testCommandCreatesBackgroundTabAndReturnsUsableIds() throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        let first = try XCTUnwrap(host.activeTab)
        XCTAssertThrowsError(try host.websiteLayoutCommand(["action": "create_tab", "profile": "default", "url": "file:///etc/passwd"]))
        XCTAssertEqual(host.tabs.count, 1)
        let created = try host.websiteLayoutCommand(["action": "create_tab", "profile": "default", "url": "http://127.0.0.1:9/"])
        let id = try XCTUnwrap(created["created"] as? UInt64)
        XCTAssertTrue(host.activeTab === first)
        let state = try host.websiteLayoutCommand(["action": "set", "profile": "default", "tabs": [first.webviewId, id], "axis": "horizontal"])
        XCTAssertEqual(state["panes"] as? [UInt64], [first.webviewId, id])
        XCTAssertEqual(state["axis"] as? String, "horizontal")
        let reset = try host.websiteLayoutCommand(["action": "reset", "profile": "default"])
        XCTAssertEqual(reset["panes"] as? [UInt64], [first.webviewId])
        XCTAssertEqual(host.tabs.count, 2)
    }
}
