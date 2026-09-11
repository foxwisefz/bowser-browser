import XCTest
import AppKit
import SwiftUI
@testable import Bowser

final class ShellThemeTests: XCTestCase {
    @MainActor func testRenderAOLControls() throws {
        guard let directory = ProcessInfo.processInfo.environment["BOWSER_THEME_RENDER"] else { return }
        defer { ChromeSurface.handle(["chrome": "set_theme", "theme": [:]]) }
        ChromeSurface.handle(["chrome": "set_theme", "theme": [
            "background": "#0047AB", "foreground": "#FFFFFF",
            "button_background": "#C0C0C0", "button_foreground": "#101010",
            "accent": "#FFD700", "border": "#666666", "button_style": "beveled",
            "show_navigation": true, "title_size": 13, "corner_radius": 2
        ]])
        let theme = ChromeSurface.theme
        let cluster = CmdCluster(profileID: "default", reveal: ChromeReveal(), tint: nil,
                                 openBar: {}, goBack: {}, goForward: {}, reload: {}, modClick: { _ in },
                                 onHoverChanged: { _ in })
        let view = NSHostingView(rootView:
            HStack {
                cluster.frame(width: 250, height: 24)
                Text("OG AOL Skin").font(.system(size: theme.titleSize, weight: .bold))
                    .foregroundStyle(Color(nsColor: theme.color("foreground")!))
                Spacer()
            }.padding(.horizontal, 15).frame(width: 800, height: 34)
                .background(Color(nsColor: theme.color("background")!))
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 34),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 34)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("aol-controls.png"))
    }
    func testRejectsMalformedWireValues() {
        for value: [String: Any] in [
            ["background": "red"], ["background": "#ffffff00"],
            ["show_navigation": 1], ["title_size": true], ["title_size": 50],
            ["corner_radius": -1], ["button_style": "unknown"], ["css": "body{}"]
        ] {
            XCTAssertNil(ShellTheme(json: value))
        }
    }

    @MainActor func testChromeProtocolAppliesAndResetsThemeAtomically() throws {
        defer { ChromeSurface.handle(["chrome": "set_theme", "theme": [:]]) }
        ChromeSurface.handle(["chrome": "set_theme", "theme": [
            "background": "#0047AB", "button_background": "#C0C0C0",
            "button_style": "beveled", "show_navigation": true, "corner_radius": 2
        ]])
        XCTAssertTrue(ChromeSurface.theme.showNavigation)
        XCTAssertEqual(ChromeSurface.theme.buttonStyle, "beveled")
        XCTAssertEqual(try XCTUnwrap(ChromeSurface.theme.color("background")).blueComponent, 171.0 / 255, accuracy: 0.001)
        let before = ChromeSurface.theme
        ChromeSurface.handle(["chrome": "set_theme", "theme": ["background": "bad"]])
        XCTAssertEqual(ChromeSurface.theme, before)
        ChromeSurface.handle(["chrome": "set_theme", "theme": [:]])
        XCTAssertEqual(ChromeSurface.theme, .native)
    }

    @MainActor func testBandPaintsAndRestoresNativeAppearance() throws {
        let band = BandScrimView(frame: NSRect(x: 0, y: 0, width: 800, height: 34))
        band.theme = try XCTUnwrap(ShellTheme(json: ["background": "#0047AB", "border": "#666666"]))
        band.updateLayer()
        XCTAssertEqual(band.layer?.backgroundColor, band.theme.color("background")?.cgColor)
        XCTAssertEqual(band.layer?.borderWidth, 1)
        band.theme = .native
        band.updateLayer()
        XCTAssertEqual(band.layer?.borderWidth, 0)
        XCTAssertEqual(band.layer?.backgroundColor, NSColor.windowBackgroundColor.withAlphaComponent(0.42).cgColor)
    }
}
