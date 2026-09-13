import AppKit
import SwiftUI
import WebKit
import BowserSurfaceKit

@MainActor func require(_ test: Bool, _ message: String) throws {
    if !test { throw NativeModuleFailure(message) }
}
@MainActor func waitFor(_ message: String, _ predicate: () async throws -> Bool) async throws {
    for _ in 0..<300 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw NativeModuleFailure(message + ": " + (NativeModuleRuntime.surfaces.lastError ?? "no loader error"))
}
@MainActor func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) }
}
@MainActor func dragTargets(_ view: NSView) -> [NSView] {
    (view is any SurfaceTabDragSource ? [view] : []) + view.subviews.flatMap { dragTargets($0) }
}
@MainActor final class Probe: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "ProbeRoot") as! String).resolvingSymlinksInPath()
            do { try await run(root) }
            catch { try? String(describing: error).write(to: root.appendingPathComponent("failure"), atomically: true, encoding: .utf8) }
            NSApp.terminate(nil)
        }
    }
    func run(_ root: URL) async throws {
        let home = root.appendingPathComponent("home-" + UUID().uuidString)
        setenv("BOWSER_HOME", home.path, 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentLayoutRect); window.contentView = content
        let note: [String: Any] = ["t":"state", "key":"note", "values":["body":""], "content":["t":"editor", "field":"body", "label":"Private note"]]
        let dock: [String: Any] = ["t":"magnify_strip", "event":"select", "items":[["id":"1", "symbol":"globe", "active":true], ["id":"2", "symbol":"star"]]]
        var actions: [[String: Any]] = []
        SurfaceServices.shared.emit = { actions.append($0) }
        var closed: [UInt64] = []
        SurfaceServices.shared.closeTab = { closed.append($0); return true }
        SurfaceServices.shared.tabSnapshot = { _ in SurfaceTabSnapshot(icon: nil, canExport: false) }
        let sidebar = NSHostingView(rootView: LiveSurfaceTree(surfaceId: "notes", node: note))
        sidebar.frame = NSRect(x: 770, y: 0, width: 330, height: 700); content.addSubview(sidebar)
        let deck = NSHostingView(rootView: LiveSurfaceTree(surfaceId: "edge_dock", node: dock))
        deck.frame = NSRect(x: 0, y: 0, width: 60, height: 700); content.addSubview(deck)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: NSRect(x: 65, y: 0, width: 700, height: 700), configuration: config); content.addSubview(web)
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        defer { web.stopLoading(); window.close() }
        web.loadFileURL(root.appendingPathComponent("fixture.html"), allowingReadAccessTo: root)
        try await waitFor("page load") { (try? await web.evaluateJavaScript("!!window.probe")) as? Bool == true }
        _ = try await web.evaluateJavaScript("video.play();true")
        try await waitFor("surface slots") { descendants(content, NativeModuleSlot.self).count == 2 }
        let slots = descendants(content, NativeModuleSlot.self)
        let model = SurfaceFormStore.shared.model(surface: "notes", key: "note", initial: [:])
        try await waitFor("editor") { model.editor("body").textView?.window != nil }
        let editor = model.editor("body").textView!
        window.makeFirstResponder(editor)
        func type(_ text: String) {
            for char in text {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: String(char), charactersIgnoringModifiers: String(char), isARepeat: false, keyCode: 0)!
                NSApp.sendEvent(event)
            }
        }
        type("Unsent note")
        try await waitFor("initial module") { slots.allSatisfy { $0.build != nil } }
        try require(model.editor("body").textView === editor, "initial admission replaced the editor")
        try require(editor.string == "Unsent note", "initial admission lost draft")
        let initial = slots[0].build!
        editor.setSelectedRange(NSRange(location: 2, length: 4))
        let before = try await web.evaluateJavaScript("probe.snapshot()") as! [String: Any]
        let publisher = home.appendingPathComponent("native-modules/surfaces")
        try FileManager.default.createDirectory(at: publisher, withIntermediateDirectories: true)
        let second = root.appendingPathComponent("Second.bundle")
        let metadata = try NativeModuleLibrary.validate(second, team: NativeModuleLibrary.runningTeam(), bundled: false, kind: .surfaces)
        try FileManager.default.copyItem(at: second, to: publisher.appendingPathComponent(metadata.0 + ".bundle"))
        // A pending drag must defer both view replacements.
        let interaction = SurfaceServices.shared.beginInteraction()
        try metadata.0.write(to: publisher.appendingPathComponent("current"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(5))
        try require(slots.allSatisfy { $0.build == initial }, "swapped during drag")
        SurfaceServices.shared.endInteraction(interaction)
        try await waitFor("second renderer") { slots.allSatisfy { $0.build == metadata.0 } }
        try require(model.editor("body").textView === editor, "editor identity changed")
        try require(editor.string == "Unsent note" && model.values["body"] as? String == "Unsent note", "draft lost")
        try require(editor.selectedRange() == NSRange(location: 2, length: 4), "selection lost")
        try require(window.firstResponder === editor, "editor focus lost")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        type(" after")
        try require(editor.string == "Unsent note after", "typing after swap failed")
        try require(editor.undoManager?.canUndo == true, "undo history lost")
        model.perform(["op":"undo", "field":"body"])
        let immediateUndo = ["editor": editor.string, "model": model.values["body"] as? String ?? ""]
        try await Task.sleep(for: .milliseconds(150))
        try JSONSerialization.data(withJSONObject: ["immediate": immediateUndo, "later": ["editor":editor.string, "model":model.values["body"] as? String ?? ""]], options: .prettyPrinted).write(to: root.appendingPathComponent("undo.json"))
        try require(editor.string != "Unsent note after", "undo failed or was overwritten")
        try require(model.values["body"] as? String == editor.string, "undo did not update the draft model")
        // Real mouse events hit the newly installed Deck Tabs renderer.
        let targets = dragTargets(deck)
        try require(!targets.isEmpty, "deck drag targets missing")
        let target = targets[0]
        try require(target.bounds.width > 0 && target.bounds.height > 0, "deck target has no geometry")
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        try await Task.sleep(for: .milliseconds(100))
        let p = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("surfaces.png"))
        }
        let hit = content.hitTest(content.convert(p, from: nil))
        try String(describing: ["point":p, "target":target.frame, "hit":String(describing: hit), "key":window.isKeyWindow, "sameWindow":target.window === window]).write(to: root.appendingPathComponent("geometry.txt"), atomically: true, encoding: .utf8)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!, atStart: false)
        }
        try await waitFor("new deck selection") { actions.contains { $0["surface"] as? String == "edge_dock" && $0["id"] as? String == "select" } }
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("surfaces.png"))
        }
        let pasteboardCount = NSPasteboard(name: .drag).changeCount
        func dragEvent(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: .option,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let outside = NSPoint(x: window.frame.width + 200, y: p.y)
        target.mouseDown(with: dragEvent(.leftMouseDown, p))
        target.mouseDragged(with: dragEvent(.leftMouseDragged, outside))
        try require(SurfaceServices.shared.hasInteractions && slots.allSatisfy { !$0.canReplace }, "live drag not leased")
        target.cancelOperation(nil)
        target.mouseUp(with: dragEvent(.leftMouseUp, outside))
        try require(closed.isEmpty && !SurfaceServices.shared.hasInteractions, "cancelled drag closed or leaked lease")
        target.mouseDown(with: dragEvent(.leftMouseDown, p))
        target.mouseDragged(with: dragEvent(.leftMouseDragged, outside))
        target.mouseUp(with: dragEvent(.leftMouseUp, outside))
        try require(closed.count == 1 && !SurfaceServices.shared.hasInteractions, "new module close gesture failed")
        try require(NSPasteboard(name: .drag).changeCount == pasteboardCount, "close gesture exported pasteboard data")
        let after = try await web.evaluateJavaScript("probe.snapshot()") as! [String: Any]
        try require(before["token"] as? String == after["token"] as? String, "page replaced")
        try require(after["paused"] as? Bool == false && (after["time"] as? Double ?? 0) > (before["time"] as? Double ?? 0), "video stopped")
        let result: [String: Any] = ["passed":true, "developerID":true, "libraryValidationDisabled":false,
            "initialBuild":initial, "activeBuild":metadata.0, "sameEditor":true, "draftAndSelectionRetained":true,
            "typingAndUndoAfterSwap":true, "dragDeferred":true, "deckAction":true, "moduleCloseAndCancel":true, "before":before, "after":after]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("result.json"))
    }
}
let app = NSApplication.shared
let delegate = Probe(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
