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

final class WarmTabTests: XCTestCase {
    @MainActor func testWarmDurationDefaultsAndClamps() {
        XCTAssertEqual(BrowserWindowController.warmDuration(nil), 8000)
        XCTAssertEqual(BrowserWindowController.warmDuration(10000), 10000)
        XCTAssertEqual(BrowserWindowController.warmDuration(50), 1000)
        XCTAssertEqual(BrowserWindowController.warmDuration(600_000), 30000)
    }
}
