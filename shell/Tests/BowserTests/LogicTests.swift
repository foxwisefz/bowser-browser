import XCTest
import WebKit
@testable import Bowser

final class NormalizeTests: XCTestCase {
    @MainActor func testSchemePassesThrough() {
        XCTAssertEqual(BrowserWindowController.normalize("https://x.com/a"), "https://x.com/a")
    }

    @MainActor func testLocalFileInputPreservesURLAndEncodesBarePaths() {
        XCTAssertEqual(BrowserWindowController.normalize(" file:///tmp/My%20Page.html#slide2 "), "file:///tmp/My%20Page.html#slide2")
        XCTAssertEqual(BrowserWindowController.normalize("/tmp/My Page#1.html"), "file:///tmp/My%20Page%231.html")
        XCTAssertEqual(BrowserWindowController.normalize("~/Documents/page.html"),
                       URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/page.html").absoluteString)
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


}

final class TabCyclingTests: XCTestCase {
    @MainActor func testWrapsBothDirections() {
        XCTAssertEqual(BrowserWindowController.wrappedIndex(1, count: 3), 1)
        XCTAssertEqual(BrowserWindowController.wrappedIndex(3, count: 3), 0)   // forward wrap
        XCTAssertEqual(BrowserWindowController.wrappedIndex(-1, count: 3), 2)  // backward wrap
        XCTAssertEqual(BrowserWindowController.wrappedIndex(0, count: 1), 0)
    }
}

@available(macOS 13.0, *)
final class AudioDubTests: XCTestCase {
    func testWavHeaderIsCanonical() {
        let wav = AudioDub.wav([0, 32767, -32768, 100], rate: 16_000)
        XCTAssertEqual(wav.count, 44 + 8) // header + 4 Int16 samples
        XCTAssertEqual(String(bytes: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(bytes: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(bytes: wav[36..<40], encoding: .ascii), "data")
        // Sample rate at byte offset 24, little-endian.
        let rate = wav[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        XCTAssertEqual(rate, 16_000)
    }

    func testDownmixAveragesChannelsAndDecimates() {
        // Stereo, 6 frames: L/R that average to a known ramp; decimate by 3.
        let interleaved: [Float32] = [
            0.0, 0.0, // frame 0 → 0
            0.5, 0.5, // 1
            1.0, 1.0, // 2
            -1.0, -1.0, // frame 3 → -1  (taken)
            0.25, 0.75, // 4
            0.5, 0.5, // 5
        ]
        let out = interleaved.withUnsafeBufferPointer {
            AudioDub.downmix($0.baseAddress!, frames: 6, channels: 2, decimate: 3)
        }
        // Frames 0 and 3 survive decimation.
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], 0)
        XCTAssertEqual(out[1], -32767)
    }

    func testDownmixPlanarAveragesChannels() {
        // Two channel buffers (planar), 4 frames; average L/R, decimate by 2.
        let left: [Float32] = [1.0, 0.0, -1.0, 0.5]
        let right: [Float32] = [1.0, 0.0, -1.0, -0.5]
        let out = left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                AudioDub.downmixPlanar([l.baseAddress!, r.baseAddress!], frames: 4, decimate: 2)
            }
        }
        // Frames 0 (avg 1.0) and 2 (avg -1.0) survive.
        XCTAssertEqual(out, [32767, -32767])
    }

    func testDownmixClampsOutOfRange() {
        let interleaved: [Float32] = [2.0, 2.0]
        let out = interleaved.withUnsafeBufferPointer {
            AudioDub.downmix($0.baseAddress!, frames: 1, channels: 2, decimate: 1)
        }
        XCTAssertEqual(out, [32767])
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

import WebKit

final class ResurrectFrameTests: XCTestCase {
    // The freeze-frame only helps when it shows the RECENT past — a frame
    // from hours ago (manual quit, laptop closed) would flash misleading
    // content (bowser-browser-9qr).
    @MainActor func testFreshnessWindow() {
        let now = Date()
        XCTAssertTrue(ResurrectFrame.shouldShow(fileDate: now.addingTimeInterval(-5), now: now))
        XCTAssertTrue(ResurrectFrame.shouldShow(fileDate: now.addingTimeInterval(-100), now: now))
        XCTAssertFalse(ResurrectFrame.shouldShow(fileDate: now.addingTimeInterval(-200), now: now))
        XCTAssertFalse(ResurrectFrame.shouldShow(fileDate: nil, now: now))
    }
}

final class TrackingPreventionTests: XCTestCase {
    // Embedded players (a YouTube embed on a third-party site) need third-party cookie
    // access to see the owner's login; ITP partitions them away
    // (bowser-browser-yll). The switch-off must take — and report honestly
    // if the SPI ever vanishes.
    @MainActor func testDisablesITPOnTheDefaultStore() {
        let store = WKWebsiteDataStore.default()
        XCTAssertTrue(EngineView.disableTrackingPrevention(on: store))
        XCTAssertEqual(store.value(forKey: "resourceLoadStatisticsEnabled") as? Bool, false)
    }
}

final class PopupConfigurationTests: XCTestCase {
    // The link-click crash (bowser-browser-pi1): createWebViewWith hands us
    // the OPENER's configuration — its user content controller already has
    // our message handlers, and a duplicate add() throws an uncaught
    // NSException. Constructing a second EngineView from the first one's
    // configuration reproduces the popup path exactly.
    @MainActor func testPopupSharingOpenerConfigurationDoesNotThrow() {
        let opener = EngineView(frame: .zero, configuration: nil)
        let popup = EngineView(frame: .zero, configuration: opener.webView.configuration)
        XCTAssertNotEqual(opener.webviewId, popup.webviewId)
        popup.tearDown()
        opener.tearDown()
    }
}

final class StripCenteringTests: XCTestCase {
    // Dock icons center vertically; the same offset feeds the proximity
    // magnification math so hover targets stay aligned (bowser-browser-2c8).
    @MainActor func testCentersAndClampsToTopWhenOverflowing() {
        // 4 icons of 28 + 8 spacing = 136 content in an 800 view → centered.
        let top = MagnifyStripView.centeredTop(viewHeight: 800, count: 4, size: 28, spacing: 8, minPad: 12)
        XCTAssertEqual(top, (800 - 136) / 2, accuracy: 0.01)
        // Content taller than the view: fall back to top-aligned.
        let overflow = MagnifyStripView.centeredTop(viewHeight: 200, count: 20, size: 28, spacing: 8, minPad: 12)
        XCTAssertEqual(overflow, 12)
        let withProfile = MagnifyStripView.centeredTop(viewHeight: 800, count: 4, size: 28, spacing: 8, minPad: 12, headerHeight: 48)
        XCTAssertEqual(withProfile, (800 - 136 - 48) / 2 + 48, accuracy: 0.01)
        XCTAssertEqual(MagnifyStripView.centeredTop(viewHeight: 200, count: 20, size: 28, spacing: 8, minPad: 12, headerHeight: 48), 60)
        // No items: harmless.
        XCTAssertEqual(MagnifyStripView.centeredTop(viewHeight: 800, count: 0, size: 28, spacing: 8, minPad: 12), 400)
    }
}

final class PanelClampTests: XCTestCase {
    // Off-screen rescue math (bowser-browser-gpi): anchored/child panels
    // must land inside the visible frame, whatever the window did.
    @MainActor func testClampsIntoVisibleFrame() {
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: 260, height: 300)
        // Way off right (fullscreen right_of_main case).
        let rescued = SurfaceManager.clamped(NSPoint(x: 1014, y: 460), size: size, in: visible)
        XCTAssertEqual(rescued.x, 1000 - 260 - 8)
        XCTAssertEqual(rescued.y, 460)
        // Way off bottom-left.
        let corner = SurfaceManager.clamped(NSPoint(x: -900, y: -900), size: size, in: visible)
        XCTAssertEqual(corner, NSPoint(x: 8, y: 8))
        // Already on screen: untouched.
        let fine = SurfaceManager.clamped(NSPoint(x: 300, y: 300), size: size, in: visible)
        XCTAssertEqual(fine, NSPoint(x: 300, y: 300))
        // Headless (no screen): pass-through.
        let headless = SurfaceManager.clamped(NSPoint(x: 5000, y: 5000), size: size, in: nil)
        XCTAssertEqual(headless, NSPoint(x: 5000, y: 5000))
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

final class ExternalApplicationHandoffTests: XCTestCase {
    func testHandsApplicationSchemesToMacOS() {
        for value in [
            "whatsapp://send?phone=971545695868&text=Hi",
            "mailto:test@example.com",
            "tel:+15551234567",
            "zoommtg://zoom.us/join",
        ] {
            XCTAssertTrue(EngineView.shouldOpenExternally(URL(string: value)), value)
        }
    }

    func testKeepsBrowserAndInternalSchemesInWebKit() {
        for value in [
            "https://example.com",
            "http://example.com",
            "file:///tmp/index.html",
            "about:blank",
            "data:text/plain,hello",
            "blob:https://example.com/id",
            "javascript:void(0)",
        ] {
            XCTAssertFalse(EngineView.shouldOpenExternally(URL(string: value)), value)
        }
        XCTAssertFalse(EngineView.shouldOpenExternally(nil))
    }
}

final class LinkClickIntentTests: XCTestCase {
    // ⌘+click opens the link in a new tab and stays put; ⌘⇧+click opens it
    // and switches (bowser-browser-0ia).
    @MainActor func testCommandClickOpensBackgroundTab() {
        XCTAssertEqual(
            EngineView.linkClickIntent(navigationType: .linkActivated, modifierFlags: .command),
            .backgroundTab
        )
    }

    @MainActor func testCommandShiftClickOpensForegroundTab() {
        XCTAssertEqual(
            EngineView.linkClickIntent(navigationType: .linkActivated,
                                       modifierFlags: [.command, .shift]),
            .foregroundTab
        )
    }

    @MainActor func testPlainClickStaysInTheSameTab() {
        XCTAssertEqual(
            EngineView.linkClickIntent(navigationType: .linkActivated, modifierFlags: []),
            .sameTab
        )
    }

    // Caps lock / fn ride along on real events; only ⌘ decides.
    @MainActor func testStrayModifiersDoNotOpenTabs() {
        XCTAssertEqual(
            EngineView.linkClickIntent(navigationType: .linkActivated,
                                       modifierFlags: [.shift, .option, .control]),
            .sameTab
        )
        XCTAssertEqual(
            EngineView.linkClickIntent(navigationType: .linkActivated,
                                       modifierFlags: [.command, .capsLock]),
            .backgroundTab
        )
    }

    // ⌘ is held for ⌘R / ⌘←; a reload or a back step is not a link click and
    // must never spawn a tab.
    @MainActor func testNonLinkNavigationIsNeverATab() {
        for type in [WKNavigationType.reload, .backForward, .formSubmitted, .other] {
            XCTAssertEqual(
                EngineView.linkClickIntent(navigationType: type, modifierFlags: .command),
                .sameTab,
                "\(type.rawValue) with ⌘ held must not open a tab"
            )
        }
    }
}
