import XCTest
@testable import Bowser

@MainActor
final class ExternalNavigationConsentTests: XCTestCase {
    func testOnlyExplicitApprovalLaunchesTheCapturedURL() {
        let consent = ExternalNavigationConsent()
        let url = URL(string: "mailto:hello@example.com")!
        var answer: (@MainActor (Bool) -> Void)?
        var opened: [URL] = []
        consent.request(url: url, present: { answer = $0 }, open: { opened.append($0) })
        XCTAssertTrue(opened.isEmpty)
        consent.request(url: URL(string: "ssh://example.com")!, present: { _ in XCTFail("Second prompt") }, open: { _ in XCTFail("Unapproved open") })
        answer?(false)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(consent.pending)
        consent.request(url: url, present: { answer = $0 }, open: { opened.append($0) })
        answer?(true)
        answer?(true)
        XCTAssertEqual(opened, [url])
    }
}
