import XCTest
@testable import Bowser

final class SurfaceRootViewTests: XCTestCase {
    /// The ✕ must be indistinguishable from the View-menu toggle for the
    /// same panel — that id is what the panels mod suppresses on.
    func testCloseClickIdMatchesViewMenuToggleId() {
        XCTAssertEqual(SurfaceRootView.closeClickId(for: "modsmith"), "panel:modsmith")
        XCTAssertEqual(SurfaceRootView.closeClickId(for: "mods"), "panel:mods")
    }
}
