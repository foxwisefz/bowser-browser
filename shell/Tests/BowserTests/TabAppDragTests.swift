import AppKit
import XCTest
import IconRendering
@testable import Bowser

final class TabAppDragTests: XCTestCase {
    @MainActor func testSavedAppIsGeneratedOnlyWhenFileRepresentationIsRequested() {
        var creations = 0
        let url = URL(fileURLWithPath: "/tmp/test-saved-app.app")
        let provider = TabAppPasteboardProvider { creations += 1; return url }
        let item = NSPasteboardItem()
        item.setString("42", forType: TabAppDragView.tabType)
        item.setDataProvider(provider, forTypes: [.fileURL])
        XCTAssertEqual(item.string(forType: TabAppDragView.tabType), "42")
        XCTAssertEqual(creations, 0)
        provider.pasteboard(nil, item: item, provideDataForType: .fileURL)
        XCTAssertEqual(item.string(forType: .fileURL), url.absoluteString)
        provider.pasteboard(nil, item: item, provideDataForType: .fileURL)
        XCTAssertEqual(creations, 1)
    }

    @MainActor
    func testCreatesReusableApplicationWithSafeLauncherAndIcon() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = URL(string: "https://example.com/dashboard?q=hello&value=$(touch%20bad)")!
        let browser = root.appendingPathComponent("Bowser's App.app")
        let source = browser.appendingPathComponent("Contents/MacOS/Bowser")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test executable".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let icon = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
        let start = ProcessInfo.processInfo.systemUptime
        let bundle = try TabAppBundle.create(url: page, profile: "work", iconData: IconRenderer.icns(icon.tiffRepresentation!), directory: root, bowser: browser, sign: false)
        print("Tab app preparation: \((ProcessInfo.processInfo.systemUptime - start) * 1000)ms")
        XCTAssertEqual(bundle.pathExtension, "app")
        let app = try XCTUnwrap(Bundle(url: bundle))
        XCTAssertEqual(app.infoDictionary?["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(app.infoDictionary?["BowserSavedURL"] as? String, page.absoluteString)
        XCTAssertEqual(app.infoDictionary?["BowserProfile"] as? String, "work")
        let executable = try XCTUnwrap(app.executableURL)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        XCTAssertEqual(try Data(contentsOf: executable), try Data(contentsOf: source))
        XCTAssertEqual(SiteAppConfiguration.parse(app.infoDictionary ?? [:])?.url, page)
        XCTAssertNotNil(NSImage(contentsOf: bundle.appendingPathComponent("Contents/Resources/SiteIcon.icns")))
        let again = try TabAppBundle.create(url: page, profile: "work", iconData: nil, directory: root, bowser: browser, sign: false)
        XCTAssertEqual(bundle, again)
        // An already-pinned v1 launcher is upgraded at exactly the same path.
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        var oldInfo = app.infoDictionary!
        oldInfo.removeValue(forKey: "BowserAppVersion")
        try PropertyListSerialization.data(fromPropertyList: oldInfo, format: .xml, options: 0).write(to: plist)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try TabAppBundle.upgrade(bundle: bundle, bowser: browser, sign: false)
        XCTAssertEqual(try Data(contentsOf: executable), try Data(contentsOf: source))
        let updated = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        XCTAssertEqual(updated["BowserAppVersion"] as? Int, 2)
        let other = try TabAppBundle.create(url: page, profile: "personal", iconData: nil, directory: root, bowser: browser, sign: false)
        XCTAssertNotEqual(bundle, other)
    }

    @MainActor
    func testRejectsNonWebLaunchTargets() {
        XCTAssertThrowsError(try TabAppBundle.create(url: URL(string: "file:///tmp/test")!, profile: "default", iconData: nil,
                                                    directory: FileManager.default.temporaryDirectory,
                                                    bowser: URL(fileURLWithPath: "/Applications/Bowser.app")))
    }
}
