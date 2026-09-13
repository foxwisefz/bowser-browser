import XCTest
import SwiftUI
import AppKit
import BowserSurfaceKit
@testable import Bowser

@MainActor final class NativeSurfaceTests: XCTestCase {
    override func setUp() async throws { try await super.setUp(); _ = NSApplication.shared }
    private func fixture(_ second: Bool = false) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[second ? "BOWSER_TEST_SURFACES_SECOND" : "BOWSER_TEST_SURFACES"] else {
            throw XCTSkip("Set BOWSER_TEST_SURFACES and BOWSER_TEST_SURFACES_SECOND to signed surface bundles")
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
    func testMappedStateLibraryIdentityExists() { XCTAssertEqual(SurfaceKitIdentity.running?.count, 32) }
    func testModuleKindsCannotBeConfused() throws {
        let bundle = try fixture()
        _ = try NativeModuleLibrary.validate(bundle, team: "V7W5LP47U9", bundled: false, kind: .surfaces)
        XCTAssertThrowsError(try NativeModuleLibrary.validate(bundle, team: "V7W5LP47U9", bundled: false))
        let library = try NativeModuleLibrary(bundle: bundle, team: "V7W5LP47U9", bundled: false, kind: .surfaces)
        let toolbar = NativeModuleSlot(fallback: NSView())
        toolbar.setSnapshot(Data("{}".utf8))
        XCTAssertFalse(toolbar.install(library))
    }
    func testDifferentStateLibraryRejectedBeforeLoading() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.copyItem(at: fixture(), to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = root.appendingPathComponent("Contents/Info.plist")
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        info["BowserSurfaceKit"] = String(repeating: "0", count: 32)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        XCTAssertThrowsError(try NativeModuleLibrary.validate(root, team: nil, bundled: true, kind: .surfaces)) { error in
            XCTAssertTrue(String(describing: error).contains("state library differs"))
        }
    }
    func testReplacementPreservesEditorAndPendingFormState() async throws {
        let a = try NativeModuleLibrary(bundle: fixture(), team: "V7W5LP47U9", bundled: false, kind: .surfaces)
        let b = try NativeModuleLibrary(bundle: fixture(true), team: "V7W5LP47U9", bundled: false, kind: .surfaces)
        let surface = "replacement-" + UUID().uuidString
        let node: [String: Any] = ["t":"state", "key":"note", "values":["text":""], "content":["t":"editor", "field":"text"]]
        let context = SurfaceRenderContext(surfaceID: surface, node: node)
        SurfaceRenderContext.contexts[context.id] = context
        let fallback = NSHostingView(rootView: SurfaceGenerationRoot(context: context, dispatch: { _ in }))
        let slot = NativeModuleSlot(fallback: fallback, kind: .surfaces)
        slot.onGenerationChange = { generation in context.generation = generation; SurfaceEditorMount.activate(owner: context.id) }
        slot.setSnapshot(try JSONSerialization.data(withJSONObject: ["context":context.id]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = slot; window.orderFront(nil)
        defer {
            slot.retire(); window.close(); SurfaceRenderContext.contexts.removeValue(forKey: context.id)
            SurfaceFormStore.shared.remove(surface: surface)
        }
        slot.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let model = SurfaceFormStore.shared.model(surface: surface, key: "note", initial: [:])
        let editor = try XCTUnwrap(model.editor("text").textView)
        editor.insertText("private draft", replacementRange: NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        XCTAssertTrue(slot.install(a))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.editor("text").textView === editor)
        XCTAssertEqual(editor.string, "private draft")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 3))
        let retiredCommand = model.editor("text").command
        let undoManager = editor.undoManager
        weak var retired = slot.subviews.last
        let request = try XCTUnwrap(model.begin(required: []))
        XCTAssertTrue(slot.install(b))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.editor("text").textView === editor)
        XCTAssertNil(retired, "retired renderer should release its view while the editor stays alive")
        retiredCommand?(["op":"insert", "text":"stale"] )
        XCTAssertEqual(editor.string, "private draft", "retired component must not edit the active document")
        XCTAssertEqual(model.pendingID, request["request_id"] as? String)
        XCTAssertEqual(model.values["text"] as? String, "private draft")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 3))
        model.refresh([:], response: ["request_id":request["request_id"]!, "ok":false, "error":"Retry"])
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.errors["_form"], "Retry")
        XCTAssertTrue(editor.undoManager === undoManager)
        try await Task.sleep(for: .milliseconds(100))
        model.perform(["op":"undo", "field":"text"])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(model.values["text"] as? String, "")
        slot.setSnapshot(Data("{}".utf8))
        slot.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(slot.build)
        XCTAssertTrue(fallback.superview === slot)
        XCTAssertTrue(model.editor("text").textView === editor)
        XCTAssertTrue(editor.isDescendant(of: fallback))
        XCTAssertEqual(model.values["text"] as? String, "")
    }
    func testPopupDefersSurfaceReplacement() {
        let slot = NativeModuleSlot(fallback: NSView(), kind: .surfaces)
        slot.setSnapshot(Data("{}".utf8))
        SurfaceServices.shared.presentations += 1
        defer { SurfaceServices.shared.presentations -= 1 }
        XCTAssertFalse(slot.canReplace)
    }
}
