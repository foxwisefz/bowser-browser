import XCTest
@testable import Bowser

final class NormalizeTests: XCTestCase {
    @MainActor func testSchemePassesThrough() {
        XCTAssertEqual(BrowserWindowController.normalize("https://x.com/a"), "https://x.com/a")
    }

    @MainActor func testBareDomainGetsHTTPS() {
        XCTAssertEqual(BrowserWindowController.normalize("news.ycombinator.com"),
                       "https://news.ycombinator.com")
    }

    @MainActor func testWordsBecomeSearch() {
        XCTAssertTrue(BrowserWindowController.normalize("pink floyd wish")
            .hasPrefix("https://duckduckgo.com/?q="))
    }

    @MainActor func testDomainWithSpacesIsSearch() {
        XCTAssertTrue(BrowserWindowController.normalize("what is x.com")
            .hasPrefix("https://duckduckgo.com/?q="))
    }
}

final class CSSColorTests: XCTestCase {
    @MainActor func testParsesRGB() {
        let c = EngineView.parseCSSColor("rgb(255, 0, 0)")
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.redComponent, 1.0, accuracy: 0.01)
    }

    @MainActor func testTransparentIsNil() {
        XCTAssertNil(EngineView.parseCSSColor("rgba(0, 0, 0, 0)"))
    }

    @MainActor func testGarbageIsNil() {
        XCTAssertNil(EngineView.parseCSSColor("bogus"))
        XCTAssertNil(EngineView.parseCSSColor(nil))
    }
}

final class LoadFailureTests: XCTestCase {
    // A cancelled navigation (-999) is routine — a new load superseded the
    // old one — and WebKit 102 is "this became a download/app link". Neither
    // is an error the user should see a page for.
    @MainActor func testCancelledNavigationShowsNoErrorPage() {
        XCTAssertFalse(EngineView.shouldShowErrorPage(domain: NSURLErrorDomain,
                                                      code: NSURLErrorCancelled))
    }

    @MainActor func testFrameLoadInterruptedShowsNoErrorPage() {
        XCTAssertFalse(EngineView.shouldShowErrorPage(domain: "WebKitErrorDomain", code: 102))
    }

    @MainActor func testDNSFailureShowsErrorPage() {
        XCTAssertTrue(EngineView.shouldShowErrorPage(domain: NSURLErrorDomain,
                                                     code: NSURLErrorCannotFindHost))
    }

    @MainActor func testErrorPageNamesTheURLAndError() {
        let html = EngineView.errorPageHTML(
            url: "https://meetings.google.com/",
            message: "A server with the specified hostname could not be found."
        )
        XCTAssertTrue(html.contains("https://meetings.google.com/"))
        XCTAssertTrue(html.contains("hostname could not be found"))
        // The URL doubles as the retry link.
        XCTAssertTrue(html.contains("href=\"https://meetings.google.com/\""))
    }

    @MainActor func testErrorPageEscapesHTML() {
        let html = EngineView.errorPageHTML(
            url: "https://x.example/<script>alert(1)</script>",
            message: "<b>bad</b>"
        )
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<b>bad</b>"))
    }
}

final class InjectedHookTests: XCTestCase {
    // The hooks are JS strings with Swift interpolation — keep the constants
    // and the scripts from drifting apart.
    @MainActor func testMediaHookUsesFreshnessWindow() {
        XCTAssertGreaterThan(EngineView.mediaResumeWindowSeconds, 0)
    }

    // The snapshot writer must not run before the restore attempt: during
    // player cold-start (bowser-browser-hj1) the element goes paused=false at
    // t=0, and an ungated writer clobbers the resume point with {t: 0}.
    @MainActor func testMediaHookWriterIsGatedOnRestore() {
        XCTAssertTrue(EngineView.mediaHook.contains("if (restored && ("))
    }
}

final class ZoomTests: XCTestCase {
    @MainActor func testStepsAndClamps() {
        XCTAssertEqual(EngineView.steppedZoom(1.0, direction: 1), 1.1, accuracy: 0.001)
        XCTAssertEqual(EngineView.steppedZoom(1.1, direction: 1), 1.2, accuracy: 0.001)
        XCTAssertEqual(EngineView.steppedZoom(1.0, direction: -1), 0.9, accuracy: 0.001)
        XCTAssertEqual(EngineView.steppedZoom(3.0, direction: 1), 3.0, accuracy: 0.001)
        XCTAssertEqual(EngineView.steppedZoom(0.5, direction: -1), 0.5, accuracy: 0.001)
        // direction 0 = Actual Size.
        XCTAssertEqual(EngineView.steppedZoom(2.3, direction: 0), 1.0, accuracy: 0.001)
    }
}

final class MenuItemTests: XCTestCase {
    // Mod menu items are ChromeSurface state driven by chrome ops, same
    // replace-by-id semantics as buttons (headless: no AppDelegate, the
    // menu rebuild is a no-op).
    @MainActor func testAddReplaceRemoveMenuItems() {
        ChromeSurface.handle(["chrome": "add_menu_item", "id": "m1", "title": "First"])
        ChromeSurface.handle(["chrome": "add_menu_item", "id": "m2", "title": "Second", "key": "e"])
        XCTAssertEqual(ChromeSurface.menuItems.map(\.id), ["m1", "m2"])
        XCTAssertEqual(ChromeSurface.menuItems.last?.key, "e")

        ChromeSurface.handle(["chrome": "add_menu_item", "id": "m1", "title": "Renamed"])
        XCTAssertEqual(ChromeSurface.menuItems.map(\.title), ["Second", "Renamed"])

        ChromeSurface.handle(["chrome": "remove_menu_item", "id": "m2"])
        ChromeSurface.handle(["chrome": "remove_menu_item", "id": "m1"])
        XCTAssertTrue(ChromeSurface.menuItems.isEmpty)
    }

    // Panel toggles need a visible checkmark state (bowser-browser-fh5).
    @MainActor func testCheckedStateRoundTrips() {
        ChromeSurface.handle(["chrome": "add_menu_item", "id": "t1", "title": "Dock", "checked": true])
        XCTAssertEqual(ChromeSurface.menuItems.last?.checked, true)
        ChromeSurface.handle(["chrome": "add_menu_item", "id": "t1", "title": "Dock", "checked": false])
        XCTAssertEqual(ChromeSurface.menuItems.last?.checked, false)
        ChromeSurface.handle(["chrome": "remove_menu_item", "id": "t1"])
    }
}

final class UserContentStoreTests: XCTestCase {
    // New webviews must be born with the brain's last-pushed content —
    // set_user_content only reaches tabs alive at push time, so without the
    // store, tabs opened later carry no site payloads (bowser-browser-1af).
    @MainActor func testRememberFollowsPutSemantics() {
        EngineView.rememberUserContent(scripts: ["a"], styles: ["s"])
        XCTAssertEqual(EngineView.sharedScripts, ["a"])
        XCTAssertEqual(EngineView.sharedStyles, ["s"])

        // nil = leave that kind untouched (matches applyUserContent).
        EngineView.rememberUserContent(scripts: ["b"], styles: nil)
        XCTAssertEqual(EngineView.sharedScripts, ["b"])
        XCTAssertEqual(EngineView.sharedStyles, ["s"])

        // [] = clear.
        EngineView.rememberUserContent(scripts: [], styles: [])
        XCTAssertEqual(EngineView.sharedScripts, [])
        XCTAssertEqual(EngineView.sharedStyles, [])
    }
}

final class WarmTabTests: XCTestCase {
    @MainActor func testWarmDurationDefaultsAndClamps() {
        XCTAssertEqual(BrowserWindowController.warmDuration(nil), 8000)
        XCTAssertEqual(BrowserWindowController.warmDuration(10000), 10000)
        XCTAssertEqual(BrowserWindowController.warmDuration(50), 1000)
        XCTAssertEqual(BrowserWindowController.warmDuration(600_000), 30000)
    }
}
