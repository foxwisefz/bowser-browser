import XCTest
import SwiftUI
import AppKit
@testable import Bowser

final class ModSmithTests: XCTestCase {
    private func snapshot(selected: String? = nil, accepted: String? = nil) -> [String: Any] {
        var data: [String: Any] = ["projects": [], "busy": false, "progress": [], "stage": "Inspecting page"]
        if let selected { data["selected"] = selected }
        if let accepted { data["accepted"] = accepted }
        return data
    }

    @MainActor func testDraftsSurviveSwitchingConversations() {
        let model = ModSmithModel()
        model.draft = "New mod idea"
        model.receive(snapshot(selected: "existing"))
        XCTAssertEqual(model.draft, "")
        model.draft = "Refinement idea"
        model.receive(snapshot())
        XCTAssertEqual(model.draft, "New mod idea")
        model.receive(snapshot(selected: "existing"))
        XCTAssertEqual(model.draft, "Refinement idea")
    }

    @MainActor func testOnlyAcceptedSubmissionClearsDraft() {
        let model = ModSmithModel()
        model.connected = { true }
        var sent: [String: Any] = [:]
        model.send = { sent = $0 }
        model.draft = "Make it larger"
        model.submit()
        XCTAssertEqual(model.draft, "Make it larger")
        model.receive(snapshot(selected: "new-project", accepted: sent["request_id"] as? String))
        model.receive(snapshot())
        XCTAssertEqual(model.draft, "")
    }

    @MainActor func testNewTypingIsNotLostBySubmissionAcknowledgement() {
        let model = ModSmithModel()
        model.connected = { true }
        var sent: [String: Any] = [:]
        model.send = { sent = $0 }
        model.draft = "First request"
        model.submit()
        model.draft = "Next idea"
        model.receive(snapshot(accepted: sent["request_id"] as? String))
        XCTAssertEqual(model.draft, "Next idea")
    }

    @MainActor func testDisconnectedSubmissionKeepsDraftAndDoesNotSend() {
        let model = ModSmithModel()
        model.connected = { false }
        model.send = { _ in XCTFail("Must not send while disconnected") }
        model.draft = "Keep this"
        model.submit()
        XCTAssertEqual(model.draft, "Keep this")
        XCTAssertNotNil(model.connectionError)
    }
    @MainActor func testExistingPickerUsesExplicitPathAndKeepsNewDraft() {
        let model = ModSmithModel()
        model.connected = { true }
        var sent: [String: Any] = [:]
        model.send = { sent = $0 }
        model.draft = "Keep my new idea"
        model.receive(["projects": [], "busy": false, "progress": [], "stage": "Ready",
                       "available_mods": [["path": "mods/reader.ex.off", "name": "Reader", "scope": "Across Bowser", "enabled": false]]])
        XCTAssertEqual(model.snapshot.available_mods?.first?.path, "mods/reader.ex.off")
        model.action("edit_existing", path: "mods/reader.ex.off")
        XCTAssertEqual(sent["action"] as? String, "edit_existing")
        XCTAssertEqual(sent["path"] as? String, "mods/reader.ex.off")
        XCTAssertEqual(model.draft, "Keep my new idea")
    }

    @MainActor func testRenderNativeWorkspace() throws {
        guard let directory = ProcessInfo.processInfo.environment["BOWSER_MODSMITH_RENDER"] else {
            throw XCTSkip("Set BOWSER_MODSMITH_RENDER for native visual verification")
        }
        _ = NSApplication.shared
        let model = ModSmithModel()
        model.targetURL = "https://example.com/article"
        let project: [String: Any] = [
            "id": "reading", "name": "Comfortable reading", "scope": "site", "url": model.targetURL,
            "status": "partial", "summary": "Larger text and a calmer layout.", "files": ["sites/example.com/reading.css"],
            "enabled": true, "can_undo": true, "undo_label": "Make the text larger",
            "turns": [
                ["id": "u", "role": "user", "text": "Make this page easier to read. Hide distractions and make the text larger."],
                ["id": "a", "role": "assistant", "text": "Added a warm background, a narrower reading column, and larger text.",
                 "notes": "The sticky navigation still needs work.", "checks": ["Confirmed the paragraph font is 20px.", "Checked that the article stays scrollable."]]
            ]
        ]
        for (name, width, filled) in [("empty", 760, false), ("result", 760, true), ("compact", 620, true)] {
            if filled {
                model.receive(["projects": [project], "selected": "reading", "busy": false, "progress": [], "stage": "Ready"])
            }
            let view = NSHostingView(rootView: ModSmithRootView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 660),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: width, height: 660)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("modsmith-\(name).png"))
        }
    }

}
