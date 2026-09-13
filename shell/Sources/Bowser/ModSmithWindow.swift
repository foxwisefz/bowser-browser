import AppKit
import SwiftUI

@MainActor
final class ModSmithModel: ObservableObject, ModSmithPresentation {
    var isSiteApp: Bool { SiteAppConfiguration.current != nil }
    @Published var snapshot = ModSmithSnapshot()
    @Published var draft = ""
    @Published var scope = "site"
    @Published var connectionError: String?
    @Published var targetURL = ""
    var targetWebview: UInt64?
    private var drafts: [String: String] = [:]
    private var pending: (id: String, key: String, text: String)?
    var track: (TelemetryEvent) -> Void = { event in Task { await Telemetry.shared.record(event) } }
    var send: ([String: Any]) -> Void = { BrainBridge.shared.send($0) }
    var connected: () -> Bool = { BrainBridge.shared.isConnected }
    var project: ModSmithProject? { snapshot.projects.first { $0.id == snapshot.selected } }
    var key: String { snapshot.selected ?? "new" }

    func receive(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let incoming = try? JSONDecoder().decode(ModSmithSnapshot.self, from: data) else { return }
        for next in incoming.projects {
            guard let previous = snapshot.projects.first(where: { $0.id == next.id }) else { continue }
            if previous.status == "working", next.status != "working" {
                let operation: TelemetryEvent.Operation = previous.files.isEmpty && previous.turns.filter({ $0.role == "user" }).count <= 1 ? .create : .refine
                track(.modsmith(operation, next.status == "active" ? .succeeded : next.status == "interrupted" ? .cancelled : .failed))
            } else if next.status == "restored", next.turns.count > previous.turns.count {
                track(.modsmith(.undo, .succeeded))
            }
        }
        drafts[key] = draft
        if let pending, incoming.accepted == pending.id {
            // Preserve anything typed after submission; clear only the accepted draft.
            if drafts[pending.key] == pending.text { drafts[pending.key] = "" }
            self.pending = nil
        }
        snapshot = incoming
        draft = drafts[key] ?? ""
        connectionError = nil
    }

    func action(_ action: String, project id: String? = nil, path: String? = nil) {
        guard connected() else { connectionError = "Connecting to Bowser. Your draft is saved here; try again shortly."; return }
        var message: [String: Any] = ["op": "event", "event": "modsmith", "action": action]
        if let id = id ?? snapshot.selected { message["project"] = id }
        if let path { message["path"] = path }
        send(message)
    }

    func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !snapshot.busy else { return }
        guard connected() else { connectionError = "Connecting to Bowser. Your draft is saved here; try again shortly."; return }
        let requestID = UUID().uuidString
        pending = (requestID, key, draft)
        var message: [String: Any] = ["op": "event", "event": "modsmith", "action": "submit", "text": text,
                                      "scope": scope, "request_id": requestID, "url": targetURL]
        if let id = snapshot.selected { message["project"] = id }
        if let id = targetWebview { message["webview"] = id }
        send(message)
    }
}

@MainActor
final class ModSmithWindow: NSObject {
    static let shared = ModSmithWindow()
    let model = ModSmithModel()
    private var window: NSWindow?

    @objc func open(_ sender: Any? = nil) {
        show()
        model.action("open")
    }

    func show() {
        model.targetWebview = (NSApp.delegate as? AppDelegate)?.currentWebviewId
        model.targetURL = SiteAppConfiguration.current?.url.absoluteString
            ?? BrowserWindowController.all.first(where: { $0.window?.isMainWindow == true })?.activeTab?.currentURLString
            ?? EngineView.live[(NSApp.delegate as? AppDelegate)?.currentWebviewId ?? 0]?.currentURLString ?? ""
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "ModSmith"
            w.subtitle = "Make Bowser yours"
            w.minSize = NSSize(width: 620, height: 480)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("ModSmithWorkspace")
            w.contentView = NSHostingView(rootView: LiveBrowserScreen(kind: "modsmith", model: model))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func receive(_ message: [String: Any]) {
        model.receive(message)
        if message["show"] as? Bool == true { show() }
    }
}

struct ModSmithRootView: View {
    let model: ModSmithModel
    var body: some View { LiveBrowserScreen(kind: "modsmith", model: model) }
}
