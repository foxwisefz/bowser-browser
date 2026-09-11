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

    func testDistributionBundleProvidesItsOwnMatchingRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let bundled = root.appendingPathComponent("Bowser.app/Contents/Resources/runtime")
        XCTAssertNil(BackendLifecycle.helper(home: home, bundledRuntime: bundled))
        for runtime in [home.appendingPathComponent("app"), bundled] {
            for name in ["bin/bowser", "brain/bin/bowser_brain"] {
                let file = runtime.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
        }
        XCTAssertEqual(BackendLifecycle.helper(home: home, bundledRuntime: bundled), bundled.appendingPathComponent("bin/bowser"))
        try FileManager.default.removeItem(at: home)
        XCTAssertEqual(BackendLifecycle.helper(home: home, bundledRuntime: bundled), bundled.appendingPathComponent("bin/bowser"))
    }
}
