import XCTest
@testable import Bowser

final class WindowControlActionTests: XCTestCase {
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
