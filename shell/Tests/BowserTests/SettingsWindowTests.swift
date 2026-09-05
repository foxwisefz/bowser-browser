import XCTest
@testable import Bowser

final class SettingsWindowTests: XCTestCase {
    func testSectionsOrderByOrderThenTitle() {
        let s = [
            SettingsWindow.Section(id: "mods", title: "Mods", order: 20, tree: [:]),
            SettingsWindow.Section(id: "zeta", title: "Zeta", order: 10, tree: [:]),
            SettingsWindow.Section(id: "settings", title: "General", order: 0, tree: [:]),
            SettingsWindow.Section(id: "profiles", title: "Profiles", order: 10, tree: [:]),
        ]
        XCTAssertEqual(SettingsWindow.ordered(s).map(\.id), ["settings", "profiles", "zeta", "mods"])
    }

    @MainActor
    func testDefaultBrowserStatusRequiresBothSchemes() {
        XCTAssertEqual(DefaultBrowserSettingsModel.status(httpIsBowser: true, httpsIsBowser: true), .isDefault)
        XCTAssertEqual(DefaultBrowserSettingsModel.status(httpIsBowser: false, httpsIsBowser: false), .notDefault)
        XCTAssertEqual(DefaultBrowserSettingsModel.status(httpIsBowser: true, httpsIsBowser: false), .partial)
        XCTAssertEqual(DefaultBrowserSettingsModel.status(httpIsBowser: false, httpsIsBowser: true), .partial)
    }

    func testExternalURLFilteringAcceptsOnlyWebSchemes() {
        let urls = [
            URL(string: "https://example.com/a")!,
            URL(string: "HTTP://example.com/b")!,
            URL(string: "file:///tmp/index.html")!,
            URL(string: "mailto:test@example.com")!,
        ]

        XCTAssertEqual(AppDelegate.webURLs(from: urls).map(\.absoluteString), [
            "https://example.com/a",
            "HTTP://example.com/b",
        ])
    }

    func testBundleDeclaresWebURLSchemes() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("bin/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }

        XCTAssertTrue(schemes.contains("http"))
        XCTAssertTrue(schemes.contains("https"))
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")

        let iconURL = plistURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("assets/AppIcon.icns")
        let attributes = try FileManager.default.attributesOfItem(atPath: iconURL.path)
        XCTAssertGreaterThan(attributes[.size] as? Int ?? 0, 0)
    }
}

final class WindowCyclingTests: XCTestCase {
    func testForwardPicksTheWindowBehindTheFrontAndBackwardTheBackmost() {
        XCTAssertEqual(AppDelegate.nextWindowIndex(count: 3, forward: true), 1)
        XCTAssertEqual(AppDelegate.nextWindowIndex(count: 3, forward: false), 2)
        XCTAssertEqual(AppDelegate.nextWindowIndex(count: 2, forward: false), 1)
        XCTAssertEqual(AppDelegate.nextWindowIndex(count: 1, forward: true), 0)
    }
}
