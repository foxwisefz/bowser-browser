import XCTest
import WebKit
@testable import Bowser

final class CookieAccessTests: XCTestCase {
    func testTargetsAndDomainBoundaries() {
        for invalid in ["", "file:///tmp/test", "https:///", "https://user:secret@example.com", "data:text/plain,hello"] {
            XCTAssertNil(CookieAccess.target(invalid))
        }
        XCTAssertNotNil(CookieAccess.target("https://example.com/path"))
        XCTAssertTrue(CookieAccess.matches(domain: ".Example.com", host: "www.example.com"))
        XCTAssertTrue(CookieAccess.matches(domain: "example.com", host: "example.com"))
        XCTAssertFalse(CookieAccess.matches(domain: "example.com", host: "notexample.com"))
        XCTAssertFalse(CookieAccess.matches(domain: "notexample.com", host: "example.com"))
        XCTAssertFalse(CookieAccess.matches(domain: "www.example.com", host: "example.com"))
        XCTAssertFalse(CookieAccess.matches(domain: "", host: "example.com"))
    }

    @MainActor func testProfileSelectionFailsClosed() {
        let original = Profile.all
        defer { Profile.all = original }
        Profile.all = [Profile.defaultProfile, Profile(id: "cookie-test", name: "Test", tint: nil, icon: nil, uuid: UUID().uuidString)]
        XCTAssertNil(CookieAccess.store(profile: nil, webview: 0))
        XCTAssertNil(CookieAccess.store(profile: "missing", webview: 0))
        XCTAssertNil(CookieAccess.store(profile: "default", webview: UInt64.max))
        XCTAssertNotNil(CookieAccess.store(profile: "default", webview: 0))
        XCTAssertNotEqual(CookieAccess.store(profile: "cookie-test", webview: 0)?.identifier,
                          CookieAccess.store(profile: "default", webview: 0)?.identifier)
    }
}
