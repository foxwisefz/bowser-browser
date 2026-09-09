import XCTest
@testable import Bowser

final class WindowControlActionTests: XCTestCase {
    @MainActor
    func testCloseControlClosesOnlyActiveTabUntilLastTab() throws {
        let controller = BrowserWindowController(profile: .defaultProfile)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let first = try XCTUnwrap(controller.activeTab)
        let second = controller.openTab()
        let third = controller.openTab()
        controller.activateTab(id: second.webviewId)

        // Exercise AppKit's real traffic-light target/action and delegate path.
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        button.performClick(nil)
        XCTAssertEqual(controller.tabs.map(\.webviewId), [first.webviewId, third.webviewId])
        XCTAssertTrue(controller.activeTab === third)
        XCTAssertTrue(BrowserWindowController.all.contains { $0 === controller })
        XCTAssertNil(EngineView.live[second.webviewId])

        WindowControlAction.close.perform(on: window)
        XCTAssertEqual(controller.tabs.map(\.webviewId), [first.webviewId])
        XCTAssertTrue(controller.activeTab === first)
        window.performClose(nil)
        XCTAssertTrue(controller.tabs.isEmpty)
        XCTAssertFalse(BrowserWindowController.all.contains { $0 === controller })
    }

    @MainActor
    func testExplicitCloseWindowStillClosesAllTabs() throws {
        let controller = BrowserWindowController(profile: .defaultProfile)
        let window = try XCTUnwrap(controller.window)
        controller.openTab()
        window.close()
        XCTAssertTrue(controller.tabs.isEmpty)
        XCTAssertFalse(BrowserWindowController.all.contains { $0 === controller })
    }

    @MainActor
    func testNativeButtonsStayVisibleAndBackgroundHoverCreatesNoPanel() throws {
        let controller = BrowserWindowController(profile: .defaultProfile)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            XCTAssertFalse(button.isHidden)
            XCTAssertTrue(button.isEnabled)
        }
        let front = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        front.makeKeyAndOrderFront(nil)
        defer { front.close() }
        let keyBefore = NSApp.keyWindow
        controller.setToolbarHovered(true)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        XCTAssertTrue(NSApp.keyWindow === keyBefore)
    }

    @MainActor
    func testCustomLightsUseTheStandardWindowResponderActions() {
        XCTAssertEqual(WindowControlAction.close.selectorName, "performClose:")
        XCTAssertEqual(WindowControlAction.minimize.selectorName, "performMiniaturize:")
        XCTAssertEqual(WindowControlAction.zoom.selectorName, "performZoom:")

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        XCTAssertTrue(window.standardWindowButton(.miniaturizeButton)?.isEnabled == true)

        for action in WindowControlAction.allCases {
            XCTAssertTrue(window.responds(to: action.selector), "NSWindow must handle \(action.selectorName)")
        }
    }


    @MainActor
    func testActionsCallTheDirectWindowMethods() {
        let window = RecordingWindow()

        WindowControlAction.minimize.perform(on: window)
        XCTAssertEqual(window.calls, ["miniaturize"])

        WindowControlAction.zoom.perform(on: window)
        XCTAssertEqual(window.calls, ["miniaturize", "zoom"])

        WindowControlAction.close.perform(on: window)
        XCTAssertEqual(window.calls, ["miniaturize", "zoom", "close"])
    }
}

@MainActor
private final class RecordingWindow: NSWindow {
    var calls: [String] = []
    override func miniaturize(_ sender: Any?) { calls.append("miniaturize") }
    override func performZoom(_ sender: Any?) { calls.append("zoom") }
    override func performClose(_ sender: Any?) { calls.append("close") }
}
