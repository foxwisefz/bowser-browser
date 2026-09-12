import AppKit
import XCTest
import SwiftUI
@testable import Bowser

@MainActor
final class SurfaceTextEditorTests: XCTestCase {
    private final class EditableText: NSTextView {
        let history = UndoManager()
        override var undoManager: UndoManager? { history }
    }
    func testFormattingPreservesUnicodeSelectionAndIsUndoable() {
        let view = EditableText(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.isRichText = false
        view.allowsUndo = true
        view.string = "Hello 🐝\nsecond line"
        view.setSelectedRange(NSRange(location: 6, length: 2))
        let editor = SurfaceEditorController()
        editor.textView = view
        view.history.beginUndoGrouping()
        editor.insert(prefix: "**", suffix: "**")
        view.history.endUndoGrouping()
        XCTAssertEqual(view.string, "Hello **🐝**\nsecond line")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 8, length: 2))
        XCTAssertTrue(view.history.canUndo)
        view.history.undo()
        XCTAssertEqual(view.string, "Hello 🐝\nsecond line")
        view.history.redo()
        XCTAssertEqual(view.string, "Hello **🐝**\nsecond line")
        view.isEditable = false
        editor.insert(prefix: "ignored", suffix: "")
        XCTAssertEqual(view.string, "Hello **🐝**\nsecond line")
    }
    func testMultilineDraftSurvivesRefreshAndAcknowledgedSave() throws {
        let form = SurfaceFormModel(["body": "original"])
        form.values["body"] = "# Heading\n\n**private** 🐝"
        form.refresh(["body": "external"], response: nil)
        XCTAssertEqual(form.values["body"] as? String, "# Heading\n\n**private** 🐝")
        let payload = try XCTUnwrap(form.begin(required: []))
        form.refresh([:], response: ["request_id": payload["request_id"]!, "ok": true])
        XCTAssertFalse(form.dirty)
        XCTAssertEqual(form.values["body"] as? String, "# Heading\n\n**private** 🐝")
    }
    func testPreviewParsesBlocksWithoutTreatingCodeAsFormatting() {
        let lines = SurfaceMarkdownPreview.lines("# Title\n- item\n> quote\n```\n# literal\n```")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].heading, 1)
        XCTAssertEqual(lines[1].text, "• item")
        XCTAssertTrue(lines[2].quote)
        XCTAssertTrue(lines[3].code)
        XCTAssertEqual(lines[3].text, "# literal")
    }
    func testInlineEditorUsesSidebarSpace() async throws {
        let node: [String: Any] = ["t": "vstack", "fill_height": true, "fill_width": true, "padding": 12, "children": [
            ["t": "text", "value": "Page Notes", "style": "heading"],
            ["t": "form", "key": "editor-layout-test", "values": ["body": ""], "fill_height": true,
             "content": ["t": "input", "field": "body", "kind": "multiline", "preview": "markdown", "label": "Page note",
                         "placeholder": "Write a note for this page…", "monospaced": true, "fill_height": true,
                         "editor_actions": [["label": "Bold", "prefix": "**", "suffix": "**"]]]]
        ]]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SurfaceTreeView(surfaceId: "editor-layout-test", node: node))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 800)
        defer { window.close(); SurfaceFormStore.shared.remove(surface: "editor-layout-test") }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let text = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        XCTAssertGreaterThan(scroll.frame.height, 500)
        XCTAssertGreaterThan(scroll.frame.width, 280)
        if let path = ProcessInfo.processInfo.environment["BOWSER_EDITOR_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func testWideSidebarsScaleToPreservePageSpace() throws {
        let bar = try XCTUnwrap(ModToolbar(json: ["id": "editor", "edge": "right", "size": 360, "view": [:]]))
        let wide = ToolbarFrames.calculate(bounds: NSRect(x: 0, y: 0, width: 1200, height: 800), bars: [bar], border: 0, topInset: 0)
        XCTAssertEqual(wide.bars["editor"]?.width, 360)
        let small = ToolbarFrames.calculate(bounds: NSRect(x: 0, y: 0, width: 300, height: 400), bars: [bar], border: 0, topInset: 0)
        XCTAssertEqual(small.page.width, 100)
        XCTAssertNil(ModToolbar(json: ["id": "too-tall", "edge": "top", "size": 360, "view": [:]]))
    }
}
