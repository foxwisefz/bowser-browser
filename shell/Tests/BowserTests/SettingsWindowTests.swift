import XCTest
@testable import Bowser

final class SettingsWindowTests: XCTestCase {
    func testSectionsOrderByOrderThenTitle() {
        let s = [
            SettingsWindow.Section(id: "mods", title: "Mods", order: 20, tree: [:]),
            SettingsWindow.Section(id: "zeta", title: "Zeta", order: 10, tree: [:]),
            SettingsWindow.Section(id: "settings", title: "General", order: 0, tree: [:]),
            SettingsWindow.Section(id: "profiles", title: "Profiles", order: 10, tree: [:]),
        ]
        XCTAssertEqual(SettingsWindow.ordered(s).map(\.id), ["settings", "profiles", "zeta", "mods"])
    }
}

final class WindowCyclingTests: XCTestCase {
    func testForwardPicksTheWindowBehindTheFrontAndBackwardTheBackmost() {
        XCTAssertEqual(AppDelegate.nextWindowIndex(count: 3, forward: true), 1)
        XCTAssertEqual(AppDelegate.nextWindowIndex(count: 3, forward: false), 2)
        XCTAssertEqual(AppDelegate.nextWindowIndex(count: 2, forward: false), 1)
        XCTAssertEqual(AppDelegate.nextWindowIndex(count: 1, forward: true), 0)
    }
}
