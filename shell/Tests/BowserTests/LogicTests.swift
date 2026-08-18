import XCTest
@testable import Bowser

final class NormalizeTests: XCTestCase {
    @MainActor func testSchemePassesThrough() {
        XCTAssertEqual(BrowserWindowController.normalize("https://x.com/a"), "https://x.com/a")
    }

    @MainActor func testBareDomainGetsHTTPS() {
        XCTAssertEqual(BrowserWindowController.normalize("news.ycombinator.com"),
                       "https://news.ycombinator.com")
    }

    @MainActor func testWordsBecomeSearch() {
        XCTAssertTrue(BrowserWindowController.normalize("pink floyd wish")
            .hasPrefix("https://duckduckgo.com/?q="))
    }

    @MainActor func testDomainWithSpacesIsSearch() {
        XCTAssertTrue(BrowserWindowController.normalize("what is x.com")
            .hasPrefix("https://duckduckgo.com/?q="))
    }
}

final class CSSColorTests: XCTestCase {
    @MainActor func testParsesRGB() {
        let c = EngineView.parseCSSColor("rgb(255, 0, 0)")
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.redComponent, 1.0, accuracy: 0.01)
    }

    @MainActor func testTransparentIsNil() {
        XCTAssertNil(EngineView.parseCSSColor("rgba(0, 0, 0, 0)"))
    }

    @MainActor func testGarbageIsNil() {
        XCTAssertNil(EngineView.parseCSSColor("bogus"))
        XCTAssertNil(EngineView.parseCSSColor(nil))
    }
}
