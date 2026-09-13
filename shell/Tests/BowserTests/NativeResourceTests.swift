import XCTest
import AppKit
@testable import Bowser

@MainActor final class NativeResourceTests: XCTestCase {
    func testJournalDeduplicatesRejectsConflictsAndNeverReexecutesEvictedCommands() {
        let journal = NativeResourceJournal(session: "native")
        var effects = 0
        func apply(_ n: Int, _ action: String = "close", session: String = "native") -> [String: Any] {
            journal.apply(["version": 1, "session": session, "sequence": n, "command": ["action": action]]) { _ in effects += 1; return ["ok": true] }
        }
        XCTAssertEqual(apply(1)["ok"] as? Bool, true)
        XCTAssertEqual(apply(1)["ok"] as? Bool, true)
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(apply(1, "move")["error"] as? String, "sequence_conflict")
        XCTAssertEqual(apply(3)["error"] as? String, "sequence_gap")
        XCTAssertEqual(apply(2, session: "other")["error"] as? String, "wrong_session_or_version")
        for n in 2...130 { _ = apply(n) }
        XCTAssertEqual(apply(1)["error"] as? String, "acknowledgement_expired")
        XCTAssertEqual(effects, 130)
    }
    func testResourcesPreserveViewsAndRejectStaleOrCrossProfileCommands() throws {
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        let first = host.activeTab!
        let second = host.openTab(activate: false)
        let service = NativeResources(session: "test")
        func command(_ sequence: Int, revision: String, profile: String = "default") -> [String: Any] {
            ["version":1, "session":"test", "sequence":sequence,
             "command":["revision":revision, "profile":profile, "window":host.resourceID, "tab":second.webviewId, "action":"move", "target":first.webviewId, "after":false]]
        }
        let revision = try XCTUnwrap(service.snapshot()["revision"] as? String)
        XCTAssertEqual(service.apply(command(1, revision: revision, profile: "work"))["error"] as? String, "unknown_resource")
        let move = command(2, revision: revision)
        XCTAssertEqual(service.apply(move)["ok"] as? Bool, true)
        XCTAssertTrue(host.tabs.first === second)
        XCTAssertTrue(host.activeTab === first)
        XCTAssertEqual(service.apply(move)["ok"] as? Bool, true)
        XCTAssertEqual(service.apply(command(3, revision: revision))["error"] as? String, "stale_resources")
        XCTAssertEqual(host.tabs.count, 2)
    }
}
