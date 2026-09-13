import AppKit
import SwiftUI
import WebKit
import XCTest
import BowserSurfaceKit
@testable import Bowser

@MainActor final class ScreenReplacementTests: XCTestCase {
    private func libraries() throws -> (NativeModuleLibrary, NativeModuleLibrary) {
        _ = NSApplication.shared
        let env = ProcessInfo.processInfo.environment
        guard let a = env["BOWSER_TEST_SCREEN_A"], let b = env["BOWSER_TEST_SCREEN_B"] else {
            throw XCTSkip("Run bin/check-native-screens")
        }
        return (try NativeModuleLibrary(bundle: URL(fileURLWithPath: a), team: nil, bundled: true, kind: .surfaces),
                try NativeModuleLibrary(bundle: URL(fileURLWithPath: b), team: nil, bundled: true, kind: .surfaces))
    }
    func testRealGenerationsKeepDraftsAndExecutePaletteActions() throws {
        let (a, b) = try libraries()
        let smith = ModSmithModel(); smith.draft = "Keep my unsent request"
        let profile = ProfileSettingsModel(profiles: [.defaultProfile], send: { _ in })
        profile.draft.name = "Unsaved name"
        let palette = CommandPaletteState(); palette.query = "example.org"
        var chosen: [CommandPaletteState.Result] = []
        palette.choose = { chosen.append($0) }
        let contexts = [BrowserScreenContext(kind: "modsmith", model: smith),
                        BrowserScreenContext(kind: "profiles", model: profile),
                        BrowserScreenContext(kind: "palette", model: palette)]
        for context in contexts {
            BrowserScreenContext.contexts[context.id] = context
            context.values["showDetails"] = true
            let slot = NativeModuleSlot(fallback: NSView(), kind: .surfaces)
            slot.setSnapshot(try JSONSerialization.data(withJSONObject: ["screen": context.id]))
            XCTAssertTrue(slot.install(a))
            let old = try XCTUnwrap(slot.subviews.last)
            XCTAssertTrue(slot.install(b))
            XCTAssertFalse(slot.subviews.last === old)
            XCTAssertEqual(context.values["showDetails"] as? Bool, true)
            if context.kind == "palette" {
                func fields(_ view: NSView) -> [NSTextField] {
                    (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
                }
                let field = try XCTUnwrap(fields(slot).first { $0.isEditable })
                XCTAssertEqual(field.stringValue, "example.org")
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(field.action), to: field.target, from: field))
            }
            slot.retire(); BrowserScreenContext.contexts.removeValue(forKey: context.id)
        }
        XCTAssertEqual(smith.draft, "Keep my unsent request")
        XCTAssertEqual(profile.draft.name, "Unsaved name")
        XCTAssertEqual(chosen.map(\.query), ["example.org"])
    }
    func testRealSplitRendererReplacementKeepsDocumentAndVideo() async throws {
        let (a, b) = try libraries()
        guard let fixture = ProcessInfo.processInfo.environment["BOWSER_SCREEN_FIXTURE"] else { throw XCTSkip("Run bin/check-native-screens") }
        let host = BrowserWindowController(profile: .defaultProfile)
        defer { host.window?.close() }
        let first = host.activeTab!, second = host.openTab(activate: false)
        let web = first.webView, url = URL(fileURLWithPath: fixture)
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        host.window?.makeKeyAndOrderFront(nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!window.probe")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await web.evaluateJavaScript("video.play(); true")
        try host.applyWebsiteLayout(tree: ["type": "row", "children": [
            ["type": "webview", "webview": first.webviewId, "weight": 3],
            ["type": "webview", "webview": second.webviewId]]])
        let layout = try XCTUnwrap(host.websiteLayout)
        let before = try await web.evaluateJavaScript("probe.snapshot()") as! [String: Any]
        let ratio = first.frame.width / layout.bounds.width
        let state = NativeUIHost.shared.state
        let context = BrowserScreenContext(kind: "native-ui", model: state)
        BrowserScreenContext.contexts[context.id] = context
        let slot = NativeModuleSlot(fallback: NSView(), kind: .surfaces)
        slot.setSnapshot(try JSONSerialization.data(withJSONObject: ["screen": context.id]))
        defer {
            slot.retire(); BrowserScreenContext.contexts.removeValue(forKey: context.id)
            NativeUIRenderer(state: state).activateScreen()
        }
        XCTAssertTrue(slot.install(a))
        let container = layout.content
        XCTAssertTrue(slot.install(b))
        XCTAssertFalse(container === layout.content)
        XCTAssertTrue(first.webView === web)
        XCTAssertTrue(first.isDescendant(of: layout))
        XCTAssertTrue(second.isDescendant(of: layout))
        XCTAssertEqual(first.frame.width / layout.bounds.width, ratio, accuracy: 0.01)
        try await Task.sleep(for: .milliseconds(500))
        let after = try await web.evaluateJavaScript("probe.snapshot()") as! [String: Any]
        XCTAssertEqual(before["token"] as? String, after["token"] as? String)
        XCTAssertGreaterThan(after["time"] as? Double ?? 0, before["time"] as? Double ?? 0)
        print("SCREEN_REPLACEMENT_PROOF retained drafts, website identity, split weights and advancing video")
    }
}
