import AppKit
import SwiftUI
import XCTest
@testable import Bowser

@MainActor
final class SurfaceAppearanceTests: XCTestCase {
    private func hex(_ color: NSColor?) -> String {
        guard let color = color?.usingColorSpace(.sRGB) else { return "none" }
        return String(format: "#%02x%02x%02x", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
    func testVariantsSemanticDefaultsAndFixedOverrides() {
        let variants = ["light": "#123456", "dark": "#abcdef", "high_contrast_light": "#000000", "high_contrast_dark": "#ffffff"]
        XCTAssertEqual(hex(SurfaceColorSpec.resolve(variants, dark: false, highContrast: false)), "#123456")
        XCTAssertEqual(hex(SurfaceColorSpec.resolve(variants, dark: true, highContrast: false)), "#abcdef")
        XCTAssertEqual(hex(SurfaceColorSpec.resolve(variants, dark: false, highContrast: true)), "#000000")
        XCTAssertEqual(hex(SurfaceColorSpec.resolve(variants, dark: true, highContrast: true)), "#ffffff")
        XCTAssertEqual(hex(SurfaceColorSpec.resolve(["light": "#123456", "dark": "#abcdef"], dark: true, highContrast: true)), "#abcdef")
        XCTAssertEqual(hex(SurfaceColorSpec.resolve("#123456", dark: true, highContrast: true)), "#123456")
        XCTAssertNotEqual(hex(SurfaceColorSpec.resolve("text", dark: false, highContrast: false)), hex(SurfaceColorSpec.resolve("text", dark: true, highContrast: false)))
        XCTAssertNotEqual(hex(SurfaceColorSpec.resolve("surface", dark: false, highContrast: false)), hex(SurfaceColorSpec.resolve("surface", dark: true, highContrast: false)))
    }
    func testPaletteReferencesAreBoundedAndDoNotLeak() {
        let first: [String: Any] = ["text": "ink", "ink": ["light": "#112233", "dark": "#ddeeff"]]
        XCTAssertEqual(hex(SurfaceColorSpec.resolve("text", palette: first, dark: true, highContrast: false)), "#ddeeff")
        XCTAssertNotEqual(hex(SurfaceColorSpec.resolve("text", dark: true, highContrast: false)), "#ddeeff")
        let cycle: [String: Any] = ["a": "b", "b": "a"]
        XCTAssertEqual(hex(SurfaceColorSpec.resolve("a", palette: cycle, dark: false, highContrast: false)), hex(SurfaceColorSpec.resolve("text", dark: false, highContrast: false)))
        XCTAssertFalse(SurfaceColorSpec.valid(["light": "#ffffff"]))
        XCTAssertFalse(SurfaceColorSpec.valid(true))
        XCTAssertFalse(SurfaceColorSpec.valid(["light": "#ffffff", "dark": "#000000", "typo": "#123456"]))
        XCTAssertNotNil(ModToolbar(json: ["id": "adaptive", "edge": "right", "size": 300, "view": [:], "style": ["foreground": "text", "background": ["light": "#ffffff", "dark": "#000000"], "palette": first]]))
        XCTAssertNil(ModToolbar(json: ["id": "bad", "edge": "right", "size": 300, "view": [:], "style": ["foreground": true]]))
    }
    func testLiveAppearanceChangeKeepsTheSameEditorDraftAndSelection() async throws {
        let palette: [String: Any] = [
            "text": ["light": "#112233", "dark": "#ddeeff", "high_contrast_dark": "#ffffff"],
            "editor_background": ["light": "#ffffff", "dark": "#111111", "high_contrast_dark": "#000000"]]
        let node: [String: Any] = ["t": "palette", "palette": palette, "content": [
            "t": "state", "key": "doc", "values": ["body": "original"], "content": ["t": "editor", "field": "body"]]]
        let surface = UUID().uuidString
        func root(_ scheme: ColorScheme) -> AnyView {
            AnyView(SurfaceTreeView(surfaceId: surface, node: node).environment(\.colorScheme, scheme))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root(.light))
        window.contentView = host
        defer { window.close(); SurfaceFormStore.shared.remove(surface: surface) }
        try await Task.sleep(for: .milliseconds(150))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(hex(editor.textColor), "#112233")
        XCTAssertEqual(hex(editor.backgroundColor), "#ffffff")
        editor.insertText("private 🐝\nsecond line", replacementRange: NSRange(location: 0, length: 8))
        editor.setSelectedRange(NSRange(location: 8, length: 2))
        let selection = editor.selectedRange()
        let undo = editor.undoManager?.canUndo
        host.rootView = root(.dark)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(descendants(host).compactMap { $0 as? NSTextView }.first === editor)
        XCTAssertEqual(editor.string, "private 🐝\nsecond line")
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.undoManager?.canUndo, undo)
        XCTAssertEqual(hex(editor.textColor), "#ddeeff")
        XCTAssertEqual(hex(editor.backgroundColor), "#111111")
        host.rootView = root(.light)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(hex(editor.textColor), "#112233")
        XCTAssertEqual(editor.string, "private 🐝\nsecond line")
    }
}
