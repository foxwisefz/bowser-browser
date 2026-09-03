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
