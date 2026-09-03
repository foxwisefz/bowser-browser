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
