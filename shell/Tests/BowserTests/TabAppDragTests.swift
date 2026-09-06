import AppKit
import XCTest
@testable import Bowser

final class TabAppDragTests: XCTestCase {
    @MainActor
    func testCreatesReusableApplicationWithSafeLauncherAndIcon() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = URL(string: "https://example.com/dashboard?q=hello&value=$(touch%20bad)")!
        let browser = URL(fileURLWithPath: "/Applications/Bowser's App.app")
        let icon = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
        let start = ProcessInfo.processInfo.systemUptime
        let bundle = try TabAppBundle.create(url: page, profile: "work", icon: icon, directory: root, bowser: browser)
        print("Tab app preparation: \((ProcessInfo.processInfo.systemUptime - start) * 1000)ms")
        XCTAssertEqual(bundle.pathExtension, "app")
        let app = try XCTUnwrap(Bundle(url: bundle))
        XCTAssertEqual(app.infoDictionary?["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(app.infoDictionary?["BowserSavedURL"] as? String, page.absoluteString)
        XCTAssertEqual(app.infoDictionary?["BowserProfile"] as? String, "work")
        let executable = try XCTUnwrap(app.executableURL)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let script = try String(contentsOf: executable, encoding: .utf8)
        XCTAssertTrue(script.contains("'/Applications/Bowser'\"'\"'s App.app'"))
        XCTAssertTrue(script.contains("-- '\(page.absoluteString)'"))
        XCTAssertNotNil(NSImage(contentsOf: bundle.appendingPathComponent("Contents/Resources/SiteIcon.icns")))
        let again = try TabAppBundle.create(url: page, profile: "work", icon: nil, directory: root, bowser: browser)
        XCTAssertEqual(bundle, again)
        let other = try TabAppBundle.create(url: page, profile: "personal", icon: nil, directory: root, bowser: browser)
        XCTAssertNotEqual(bundle, other)
    }

    @MainActor
    func testRejectsNonWebLaunchTargets() {
        XCTAssertThrowsError(try TabAppBundle.create(url: URL(string: "file:///tmp/test")!, profile: "default", icon: nil,
                                                    directory: FileManager.default.temporaryDirectory,
                                                    bowser: URL(fileURLWithPath: "/Applications/Bowser.app")))
    }
}
