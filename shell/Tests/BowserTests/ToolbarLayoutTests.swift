import XCTest
import AppKit
@testable import Bowser

final class ToolbarLayoutTests: XCTestCase {
    private func bar(_ id: String, _ edge: String, _ size: Double) -> ModToolbar {
        ModToolbar(json: ["id": id, "edge": edge, "size": size, "view": ["t": "text", "text": id]])!
    }
    func testEveryEdgeReservesSpaceAndRemovalRestoresNativeFrame() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        let bars = [bar("top", "top", 40), bar("bottom", "bottom", 28), bar("left", "left", 100), bar("right", "right", 80)]
        let layout = ToolbarFrames.calculate(bounds: bounds, bars: bars, border: 4, topInset: 34)
        XCTAssertEqual(layout.page, NSRect(x: 104, y: 32, width: 612, height: 528))
        let content = NSRect(x: layout.page.minX, y: layout.page.minY, width: layout.page.width, height: layout.page.height - 34)
        for frame in layout.bars.values { XCTAssertFalse(content.intersects(frame)) }
        XCTAssertEqual(ToolbarFrames.calculate(bounds: bounds, bars: [], border: 0, topInset: 34).page, bounds)
    }
    func testSmallWindowKeepsPageAndBarsWithinBounds() {
        let bounds = NSRect(x: 0, y: 0, width: 220, height: 180)
        let layout = ToolbarFrames.calculate(bounds: bounds, bars: [bar("left", "left", 200), bar("right", "right", 200), bar("bottom", "bottom", 200)], border: 12, topInset: 34)
        XCTAssertGreaterThanOrEqual(layout.page.width, 100)
        XCTAssertGreaterThanOrEqual(layout.page.height, 100)
        for frame in layout.bars.values { XCTAssertTrue(bounds.contains(frame)) }
    }
    @MainActor func testContainerAppliesAndRemovesBarsAndBorderWithoutInterceptingClicks() throws {
        let container = ToolbarContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.setBars([bar("status", "bottom", 28)])
        XCTAssertEqual(container.pageArea.frame.minY, 28)
        container.setBars([])
        XCTAssertEqual(container.pageArea.frame, container.bounds)
        let border = WindowBorderView(frame: container.bounds)
        border.theme = try XCTUnwrap(ShellTheme(json: ["window_border": "#808080", "window_border_width": 4, "window_border_style": "beveled"]))
        XCTAssertNil(border.hitTest(NSPoint(x: 2, y: 2)))
        XCTAssertNil(ShellTheme(json: ["window_border_width": true]))
    }
}
