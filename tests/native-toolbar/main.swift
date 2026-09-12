import AppKit
import WebKit

@MainActor func require(_ test: Bool, _ message: String) throws {
    if !test { throw NativeToolbarFailure(message) }
}
@MainActor func waitFor(_ message: String, _ predicate: () async throws -> Bool) async throws {
    for _ in 0..<300 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw NativeToolbarFailure(message + ": " + (NativeToolbarRuntime.shared.lastError ?? "no loader error"))
}
@MainActor func clickCommand(_ slot: NSView, _ window: NSWindow) {
    let point = slot.convert(NSPoint(x: 25, y: 12), to: nil)
    for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        NSApp.postEvent(event, atStart: false)
    }
}
@MainActor final class Probe: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "ProbeRoot") as! String).resolvingSymlinksInPath()
            do { try await run(root); try "passed".write(to: root.appendingPathComponent("passed"), atomically: true, encoding: .utf8) }
            catch { try? String(describing: error).write(to: root.appendingPathComponent("failure"), atomically: true, encoding: .utf8) }
            NSApp.terminate(nil)
        }
    }
    func run(_ root: URL) async throws {
        setenv("BOWSER_HOME", root.appendingPathComponent("home").path, 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content
        let slot = NativeToolbarSlot(fallback: NSTextField(labelWithString: "Loading toolbar"))
        slot.frame = NSRect(x: 0, y: 660, width: 500, height: 30)
        let state: [String: Any] = ["revealed": true,"tint": NSNull(),"colors": [:],"buttonStyle": "flat","cornerRadius": 6,"showNavigation": true,"buttons": [["id":"probe","title":"Probe action","symbol":"star"]]]
        slot.setSnapshot(try JSONSerialization.data(withJSONObject: state))
        var actions: [String] = []
        slot.onAction = { actions.append($0) }
        content.addSubview(slot)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 650), configuration: config)
        content.addSubview(web)
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        defer { slot.retire(); web.stopLoading(); window.close() }
        web.loadFileURL(root.appendingPathComponent("fixture.html"), allowingReadAccessTo: root)
        try await waitFor("page load") { (try? await web.evaluateJavaScript("!!window.probe")) as? Bool == true }
        _ = try await web.evaluateJavaScript("video.play();draft.focus();draft.value='unsent';draft.setSelectionRange(6,6);true")
        try await waitFor("signed module admission") { slot.build != nil }
        let initial = slot.build!
        try require(NativeToolbarLibrary.runningTeam() == "V7W5LP47U9", "probe not Developer ID signed")
        try await Task.sleep(for: .milliseconds(300))
        clickCommand(slot, window)
        try await waitFor("native command action") { actions.contains("command") }
        let before = try await web.evaluateJavaScript("probe.snapshot()") as! [String: Any]
        let page = ObjectIdentifier(web)
        window.makeFirstResponder(web)
        // Deliver real AppKit key events to the focused webpage, not JS value assignment.
        func type(_ text: String) {
            for char in text {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: String(char), charactersIgnoringModifiers: String(char), isARepeat: false, keyCode: 0)!
                NSApp.sendEvent(event)
            }
        }
        _ = try await web.evaluateJavaScript("draft.focus();true")
        let publisher = root.appendingPathComponent("home/native-modules/command-toolbar")
        try FileManager.default.createDirectory(at: publisher, withIntermediateDirectories: true)
        let second = root.appendingPathComponent("Second.bundle")
        let metadata = try NativeToolbarLibrary.validate(second, team: "V7W5LP47U9", bundled: false)
        try FileManager.default.copyItem(at: second, to: publisher.appendingPathComponent(metadata.0 + ".bundle"))
        try metadata.0.write(to: publisher.appendingPathComponent("current"), atomically: true, encoding: .utf8)
        type(" before")
        try await waitFor("live signed replacement") { slot.build == metadata.0 }
        type(" after")
        try await waitFor("typed draft preserved") { (try? await web.evaluateJavaScript("draft.value")) as? String == "unsent before after" }
        try require(initial != slot.build && ObjectIdentifier(web) == page, "page recreated")
        try await Task.sleep(for: .milliseconds(300))
        clickCommand(slot, window)
        try await waitFor("new toolbar action") { actions.filter { $0 == "command" }.count == 2 }
        let after = try await web.evaluateJavaScript("probe.snapshot()") as! [String: Any]
        try require(before["token"] as? String == after["token"] as? String, "document replaced")
        try require(after["paused"] as? Bool == false && (after["time"] as? Double ?? 0) > (before["time"] as? Double ?? 0), "video stopped")
        let result: [String: Any] = ["passed":true,"developerID":true,"libraryValidationDisabled":false,"initialBuild":initial,"activeBuild":slot.build!,"typedDraft":"unsent before after","commandActions":2,"sameWebView":true,"before":before,"after":after]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("result.json"))
    }
}
let app = NSApplication.shared
let delegate = Probe(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
