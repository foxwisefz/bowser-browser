import XCTest
@testable import Bowser

final class SafariUserAgentTests: XCTestCase {
    func testSafariBundleVersionsUseMajorAndMinor() {
        XCTAssertEqual(SafariUserAgent.safariVersion("26.6.2"), "26.6")
        XCTAssertEqual(SafariUserAgent.safariVersion("18.6"), "18.6")
        for value in ["", "26", "26..2", "26.6 beta", "0.1"] {
            XCTAssertNil(SafariUserAgent.safariVersion(value))
        }
    }

    func testUserAgentReportsOnlySafariBranding() {
        XCTAssertTrue(SafariUserAgent.current.contains("Version/"))
        XCTAssertTrue(SafariUserAgent.current.hasSuffix("Safari/605.1.15"))
        XCTAssertFalse(SafariUserAgent.current.contains("Bowser"))
    }
}
