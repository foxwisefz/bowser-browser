import AppKit
import XCTest
@testable import Bowser

@MainActor final class ResourceWorkflowTests: XCTestCase {
    func testNavigationPolicyReplacesAtomicallyAndKeepsNonLinkNavigationInPlace() {
        let policy = NavigationPolicy()
        XCTAssertEqual(policy.intent(type: .linkActivated, modifiers: .command), .backgroundTab)
        XCTAssertTrue(policy.update([["required":["command"], "forbidden":["option"], "action":"foreground_tab"]]))
        XCTAssertEqual(policy.intent(type: .linkActivated, modifiers: .command), .foregroundTab)
        XCTAssertEqual(policy.intent(type: .reload, modifiers: .command), .sameTab)
        XCTAssertEqual(policy.intent(type: .linkActivated, modifiers: [.command,.option]), .sameTab)
        XCTAssertFalse(policy.update([["required":["command"], "forbidden":[], "action":"execute"]]))
        XCTAssertEqual(policy.intent(type: .linkActivated, modifiers: .command), .foregroundTab)
    }
    func testPendingDownloadOutlivesTabAndCompletionRunsOnceWithCollisionReservation() throws {
        let downloads = NativeDownloads.shared
        let id = UUID().uuidString, other = UUID().uuidString
        defer { downloads.cancelDestination(id); downloads.cancelDestination(other) }
        var destinations: [URL] = []
        let filename = "bowser-fixture-" + UUID().uuidString + ".bin"
        downloads.stage(id: id, tab: 900, profile: "work", suggested: filename) { if let url = $0 { destinations.append(url) } }
        let command: [String: Any] = ["download":id, "profile":"work", "filename":filename]
        XCTAssertFalse(downloads.choose(["download":id, "profile":"default", "filename":filename]))
        XCTAssertTrue(downloads.choose(command)) // no live tab 900 required
        XCTAssertFalse(downloads.choose(command))
        downloads.stage(id: other, tab: 900, profile: "work", suggested: filename) { if let url = $0 { destinations.append(url) } }
        XCTAssertTrue(downloads.choose(["download":other, "profile":"work", "filename":filename]))
        XCTAssertEqual(destinations.count, 2)
        XCTAssertNotEqual(destinations[0], destinations[1])
        XCTAssertEqual(destinations[0].lastPathComponent, filename)
    }
    func testDestinationRejectsPathsAndCancellationCompletesPendingCallback() {
        let downloads = NativeDownloads.shared, id = UUID().uuidString
        var calls = 0
        downloads.stage(id: id, tab: 1, profile: "default", suggested: "../../private") { url in calls += 1; XCTAssertNil(url) }
        XCTAssertFalse(downloads.choose(["download":id, "profile":"default", "filename":"../../private"]))
        downloads.cancelDestination(id); downloads.cancelDestination(id)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(NativeDownloads.safeFilename("../../private"), "private")
    }
}
