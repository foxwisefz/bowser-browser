import AppKit
import XCTest
@testable import Bowser

final class TabOrderTests: XCTestCase {
    @MainActor func testReorderKeepsActivePageAndRejectsForeignTabs() {
        let host = BrowserWindowController(profile: .defaultProfile)
        let other = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close(); other.window?.close() }
        let first = host.activeTab!
        let second = host.openTab(activate: false, append: true)
        let third = host.openTab(activate: false, append: true)
        XCTAssertTrue(host.moveTab(id: third.webviewId, relativeTo: first.webviewId, after: false))
        XCTAssertEqual(host.tabs.map(\.webviewId), [third, first, second].map(\.webviewId))
        XCTAssertTrue(host.activeTab === first)
        XCTAssertTrue(host.moveTab(id: third.webviewId, relativeTo: second.webviewId, after: true))
        XCTAssertEqual(host.tabs.map(\.webviewId), [first, second, third].map(\.webviewId))
        XCTAssertFalse(host.moveTab(id: third.webviewId, relativeTo: other.activeTab.webviewId, after: false))
        XCTAssertFalse(host.moveTab(id: third.webviewId, relativeTo: third.webviewId, after: false))
        XCTAssertTrue(host.activeTab === first)
    }

    @MainActor func testInsertionAndRestoreAppendKeepNavigationOrder() {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        let first = host.activeTab!
        let last = host.openTab(activate: false, append: true)
        let inserted = host.openTab(activate: false)
        XCTAssertEqual(host.tabs.map(\.webviewId), [first, inserted, last].map(\.webviewId))
        XCTAssertTrue(host.activeTab === first)
        host.activateAdjacentTab(offset: 1)
        XCTAssertTrue(host.activeTab === inserted)
        let next = host.openTab(activate: true)
        XCTAssertEqual(host.tabs.map(\.webviewId), [first, inserted, next, last].map(\.webviewId))
        let restored = host.openTab(activate: false, append: true)
        XCTAssertTrue(host.tabs.last === restored)
        XCTAssertTrue(host.activeTab === next)
    }
}
