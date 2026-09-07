import XCTest
import SwiftUI
@testable import Bowser

final class SurfaceStateTests: XCTestCase {
    @MainActor
    func testKeyedInsertionPreservesActualTextFieldFocus() throws {
        _ = NSApplication.shared
        let field: [String: Any] = ["t": "textfield", "key": "name", "event": "name", "value": "Reading"]
        let host = NSHostingView(rootView: SurfaceTreeView(surfaceId: "focus-test", node: ["t": "vstack", "children": [field]]))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        window.makeFirstResponder(editor)
        let responder = try XCTUnwrap(window.firstResponder)
        host.rootView = SurfaceTreeView(surfaceId: "focus-test", node: ["t": "vstack", "children": [
            ["t": "text", "key": "notice", "value": "New status"], field
        ]])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertTrue(descendants(host).contains { $0 === editor })
    }

    @MainActor
    func testLegacyControlRefreshDoesNotEmitUserEvents() {
        _ = NSApplication.shared
        var events = 0
        let toggle = NSHostingView(rootView: SurfaceToggle(eventId: "switch", initial: false, payload: nil, label: "Switch", emit: { _, _ in events += 1 }))
        let color = NSHostingView(rootView: SurfaceColorPicker(eventId: "color", initialHex: "#ff0000", label: "Color", emit: { _, _ in events += 1 }))
        toggle.frame = NSRect(x: 0, y: 0, width: 200, height: 50)
        color.frame = toggle.frame
        toggle.layoutSubtreeIfNeeded(); color.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        toggle.rootView = SurfaceToggle(eventId: "switch", initial: true, payload: nil, label: "Switch", emit: { _, _ in events += 1 })
        color.rootView = SurfaceColorPicker(eventId: "color", initialHex: "#0000ff", label: "Color", emit: { _, _ in events += 1 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        XCTAssertEqual(events, 0)
    }

    @MainActor
    func testPopoverChoiceEditsEnclosingFormDraft() throws {
        _ = NSApplication.shared
        let surface = "popover-binding-test"
        let model = SurfaceFormStore.shared.model(surface: surface, key: "form", initial: ["icon": "book"])
        let tree: [String: Any] = ["t": "form", "key": "form", "values": ["icon": "book"], "content": [
            "t": "popover", "key": "picker", "label": "Pick icon", "content_width": 260.0,
            "content": ["t": "input", "field": "icon", "kind": "choice", "options": [
                ["value": "star", "label": "Star", "symbol": "star"]
            ]]
        ]]
        let host = NSHostingView(rootView: SurfaceTreeView(surfaceId: surface, node: tree))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { model.reset(); window.orderOut(nil); SurfaceFormStore.shared.remove(surface: surface) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        try pressButton("Pick icon", in: host, at: NSPoint(x: 45, y: host.bounds.midY - 20))
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let popup = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0.isVisible })
        defer { popup.orderOut(nil) }
        let content = try XCTUnwrap(popup.contentView)
        // Tahoe adds popover chrome around the requested content width.
        XCTAssertGreaterThanOrEqual(content.bounds.width, 260)
        let point = content.convert(NSPoint(x: 50, y: content.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            popup.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.values["icon"] as? String, "star")
        XCTAssertTrue(model.dirty)
    }

    @MainActor
    func testNativeSheetOpensAndDismissActionClosesIt() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SurfaceTreeView(surfaceId: "sheet-test", node: [
            "t": "sheet", "key": "help", "label": "Help", "content_width": 300.0,
            "content": ["t": "action", "label": "Done", "action": "dismiss", "role": "primary"]
        ]))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try pressButton("Help", in: host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        try pressButton("Done", in: content)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(window.attachedSheet)
    }

    @MainActor
    private func pressButton(_ label: String, in view: NSView, at location: NSPoint? = nil) throws {
        // Deliver real window events at the fixture action:
        // SwiftUI no longer promises an NSButton backing view on Tahoe.
        let window = try XCTUnwrap(view.window)
        view.layoutSubtreeIfNeeded()
        let point = view.convert(location ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1), "Cannot click \(label)")
            window.sendEvent(event)
        }
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
