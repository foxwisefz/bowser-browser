import AppKit
import SwiftUI
import XCTest
@testable import Bowser

@MainActor
final class SurfaceCompositionTests: XCTestCase {
    func testCommandsBindToTheirOwnModelAndReportExplicitFields() throws {
        let a = SurfaceFormModel(["body": "alpha", "mode": "write", "secret": "hidden"])
        let b = SurfaceFormModel(["body": "beta", "mode": "write"])
        a.perform(["op": "set", "field": "mode", "value": "preview"])
        XCTAssertEqual(a.values["mode"] as? String, "preview")
        XCTAssertEqual(b.values["mode"] as? String, "write")
        a.perform(["op": "toggle", "field": "visible"])
        XCTAssertEqual(a.values["visible"] as? Bool, true)
        let snapshot = try XCTUnwrap(a.perform(["op": "snapshot", "fields": ["body"]]))
        XCTAssertEqual(snapshot["values"] as? [String: String], ["body": "alpha"])
        let payload = try XCTUnwrap(a.perform(["op": "submit"]))
        a.perform(["op": "set", "field": "body", "value": "ignored while saving"])
        XCTAssertEqual(a.values["body"] as? String, "alpha")
        a.refresh([:], response: ["request_id": payload["request_id"]!, "ok": true])
        a.perform(["op": "set", "field": "body", "value": "change"])
        a.perform(["op": "reset"])
        XCTAssertEqual(a.values["body"] as? String, "alpha")
    }

    func testTransientUIStateDoesNotBecomeAnUnsavedDocument() {
        let model = SurfaceFormModel(["body": "note", "mode": "write"], trackedFields: ["body"])
        model.perform(["op": "set", "field": "mode", "value": "preview"])
        XCTAssertFalse(model.dirty)
        model.refresh(["body": "note", "mode": "write"], response: nil)
        XCTAssertEqual(model.values["mode"] as? String, "preview")
        model.perform(["op": "set", "field": "body", "value": "draft"])
        XCTAssertTrue(model.dirty)
        model.refresh(["body": "external", "mode": "write"], response: nil)
        XCTAssertEqual(model.values["body"] as? String, "draft")
    }

    func testSiblingCommandUsesEditorSelectionAndUpdatesBoundDraft() throws {
        let model = SurfaceFormModel(["body": "A 🐝 note"])
        let controller = model.editor("body")
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let native = SurfaceNativeTextEditor(text: Binding(get: { model.values["body"] as? String ?? "" }, set: { model.values["body"] = $0 }), controller: controller,
            monospaced: false, editable: true, label: "Note")
        let coordinator = native.makeCoordinator()
        view.delegate = coordinator
        view.isRichText = false
        view.string = "A 🐝 note"
        controller.textView = view
        model.perform(["op": "select", "field": "body", "location": 2, "length": 2])
        model.perform(["op": "wrap", "field": "body", "prefix": "**", "suffix": "**"])
        XCTAssertEqual(view.string, "A **🐝** note")
        XCTAssertEqual(model.values["body"] as? String, view.string)
        let snapshot = try XCTUnwrap(model.perform(["op": "snapshot", "fields": ["body"]]))
        let selection = try XCTUnwrap((snapshot["selections"] as? [String: [String: Int]])?["body"])
        XCTAssertEqual(selection, ["location": 4, "length": 2])
        model.perform(["op": "insert", "field": "body", "text": "bee\nsecond line"])
        XCTAssertEqual(model.values["body"] as? String, "A **bee\nsecond line** note")
        let other = SurfaceFormModel(["body": "other"])
        other.perform(["op": "wrap", "field": "body", "prefix": "oops", "suffix": ""])
        XCTAssertEqual(view.string, "A **bee\nsecond line** note")
    }

    func testWrappingFitsArbitraryControlsAtNarrowWidths() {
        let sizes = Array(repeating: CGSize(width: 28, height: 28), count: 8)
        let wide = SurfaceFlowLayout.frames(sizes: sizes, width: 300, spacing: 6)
        XCTAssertEqual(Set(wide.map(\.minY)), [0])
        let narrow = SurfaceFlowLayout.frames(sizes: sizes, width: 120, spacing: 6)
        XCTAssertGreaterThan(Set(narrow.map(\.minY)).count, 1)
        XCTAssertTrue(narrow.allSatisfy { $0.minX >= 0 && $0.maxX <= 120 })
        XCTAssertEqual(SurfaceFlowLayout.frames(sizes: [CGSize(width: 500, height: 20)], width: 100, spacing: 6)[0].width, 100)
    }

    func testScopeIdentityChangesDocumentsWithoutSharingWindowDrafts() async throws {
        let namespace = UUID().uuidString
        let surface = "scope-test"
        func node(_ key: String, _ value: String) -> [String: Any] {
            ["t": "state", "key": key, "values": ["body": value], "content": ["t": "editor", "field": "body"]]
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SurfaceTreeView(surfaceId: surface, node: node("a", "first")).environment(\.surfaceStateNamespace, namespace))
        window.contentView = host
        defer { window.close(); SurfaceFormStore.shared.remove(surface: namespace + "|" + surface) }
        try await Task.sleep(for: .milliseconds(100))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let first = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
        first.insertText("draft", replacementRange: NSRange(location: 0, length: 5))
        host.rootView = SurfaceTreeView(surfaceId: surface, node: node("b", "second")).environment(\.surfaceStateNamespace, namespace)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(descendants(host).compactMap { $0 as? NSTextView }.first?.string, "second")
        host.rootView = SurfaceTreeView(surfaceId: surface, node: node("a", "first")).environment(\.surfaceStateNamespace, namespace)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(descendants(host).compactMap { $0 as? NSTextView }.first?.string, "draft")
        let other = SurfaceFormStore.shared.model(surface: "other-window|" + surface, key: "a", initial: ["body": "first"])
        XCTAssertEqual(other.values["body"] as? String, "first")
        SurfaceFormStore.shared.remove(surface: "other-window|" + surface)
    }
}
