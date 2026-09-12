import AppKit
import XCTest
@testable import Bowser

final class TabOrderTests: XCTestCase {
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
