import XCTest
import BowserSurfaceKit
@testable import Bowser

@MainActor final class NativeUIPresentationTests: XCTestCase {
    override func setUp() async throws { _ = NSApplication.shared }
    func testMenuPresentationPreservesNativeActionRouting() {
        let target = NSObject()
        let menu = NativeUIPresentation.menus(NativeMenuContext(target: target, siteHost: nil,
            targets: ["modsmith": target], siteActions: []))
        let file = menu.main.items.first { $0.submenu?.title == "File" }?.submenu
        XCTAssertEqual(file?.items.first?.action, NSSelectorFromString("newTab:"))
        XCTAssertNotNil(menu.profiles)
        let smith = menu.mods.items.first { $0.action == NSSelectorFromString("open:") }
        XCTAssertTrue(smith?.target === target)
        let pip = menu.mods.items.first { $0.action == NSSelectorFromString("togglePictureInPicture:") }
        XCTAssertEqual(pip?.keyEquivalentModifierMask, [.command, .option])
    }
    func testSiteMenusKeepBrowserOnlyActionsOut() {
        let menu = NativeUIPresentation.menus(NativeMenuContext(target: NSObject(), siteHost: "example.com", targets: [:], siteActions: ["Back"]))
        XCTAssertNil(menu.profiles)
        let file = menu.main.items.first { $0.submenu?.title == "File" }?.submenu
        XCTAssertFalse(file?.items.contains { $0.action == NSSelectorFromString("newTab:") } ?? true)
    }
    func testExternalPromptDefaultsToCancellation() {
        let alert = NativeUIPresentation.alert("external", ["name": "Example", "source": "https://example.com"])
        XCTAssertEqual(alert.buttons.count, 2)
        XCTAssertEqual(alert.buttons.first?.title, "Cancel")
        XCTAssertEqual(alert.buttons.last?.title, "Open")
    }
}
