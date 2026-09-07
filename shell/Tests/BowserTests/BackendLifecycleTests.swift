import XCTest
@testable import Bowser

@MainActor
final class BackendLifecycleTests: XCTestCase {
    func testClosingLastMainWindowDoesNotTerminateApplication() {
        XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    func testBootstrapRequiresBothHelperAndInstalledRuntime() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let helper = home.appendingPathComponent("app/bin/bowser")
        let release = home.appendingPathComponent("app/brain/bin/bowser_brain")
        XCTAssertNil(BackendLifecycle.helper(home: home))
        for file in [helper, release] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            if file == helper { XCTAssertNil(BackendLifecycle.helper(home: home)) }
        }
        XCTAssertEqual(BackendLifecycle.helper(home: home), helper)
    }
}
