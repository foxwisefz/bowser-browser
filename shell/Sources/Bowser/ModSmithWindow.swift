import AppKit
import SwiftUI

struct ModSmithTurn: Decodable, Identifiable {
    let id: String
    let role: String
    let text: String
    var status: String?
    var notes: String?
    var checks: [String]?
}

struct ModSmithProject: Decodable, Identifiable {
    let id: String
    let name: String
    let scope: String
    let url: String
    let status: String
    let summary: String
    let turns: [ModSmithTurn]
    let files: [String]
    let enabled: Bool
    let canUndo: Bool
    let undoLabel: String?
    enum CodingKeys: String, CodingKey {
        case id, name, scope, url, status, summary, turns, files, enabled
        case canUndo = "can_undo", undoLabel = "undo_label"
    }
    var scopeLabel: String {
        switch scope {
        case "browser": return "Across Bowser"
        case "app": return "Only this app"
        default: return "\(URL(string: url)?.host ?? url) · includes subdomains"
        }
    }
    var statusLabel: String {
        switch status {
        case "working": return "Working"
        case "partial": return "Partially complete"
        case "failed": return "Needs attention"
        case "needs_help": return "Needs more help"
        case "interrupted": return "Interrupted"
        case "restored": return files.isEmpty ? "Removed" : "Restored"
        case "ready": return "Ready to edit"
        default: return enabled ? "Active" : "Disabled"
        }
    }
}

struct ModSmithSnapshot: Decodable {
    var projects: [ModSmithProject] = []
    var selected: String?
    var busy = false
    var accepted: String?
    var error: String?
    var progress: [String] = []
    var stage = "Inspecting page"
}

@MainActor
final class ModSmithModel: ObservableObject {
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

    func action(_ action: String, project id: String? = nil) {
        guard connected() else { connectionError = "Connecting to Bowser. Your draft is saved here; try again shortly."; return }
        var message: [String: Any] = ["op": "event", "event": "modsmith", "action": action]
        if let id = id ?? snapshot.selected { message["project"] = id }
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
            w.contentView = NSHostingView(rootView: ModSmithRootView(model: model))
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
    @ObservedObject var model: ModSmithModel
    @FocusState private var composerFocused: Bool
    @State private var showDetails = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                conversation
                composer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { composerFocused = true }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your mods", systemImage: "sparkles").font(.headline).padding(.top, 8)
            Button { model.action("new") } label: {
                Label("New mod", systemImage: "plus").frame(maxWidth: .infinity)
            }.controlSize(.large)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.snapshot.projects) { project in
                        Button { model.action("select", project: project.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(project.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                Text(project.statusLabel).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(model.snapshot.selected == project.id ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("Changes happen live.\nMake a mod, then make it yours.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }.padding(16).frame(width: 190).background(.quaternary.opacity(0.25))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(model.project?.name ?? "What would you change?")
                .font(.system(size: 20, weight: .semibold)).lineLimit(2)
            if let project = model.project {
                HStack {
                    Label(project.scopeLabel, systemImage: project.scope == "browser" ? "macwindow" : "globe")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(project.statusLabel).font(.caption.weight(.medium))
                }
                HStack {
                    if project.canUndo {
                        Button("Undo last change", systemImage: "arrow.uturn.backward") { model.action("undo") }
                            .help("Restore mod files before: \(project.undoLabel ?? "last change"). Website actions and stored mod data are not reversed.")
                    }
                    if !project.files.isEmpty {
                        Button(project.enabled ? "Disable" : "Enable", systemImage: project.enabled ? "pause.circle" : "play.circle") {
                            model.action("toggle")
                        }
                    }
                }.controlSize(.small).disabled(model.snapshot.busy)
                if project.canUndo {
                    Text("Undo restores mod files. Website actions and saved mod data stay as they are.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else if SiteAppConfiguration.current != nil {
                Label("Only this app", systemImage: "app").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Applies to", selection: $model.scope) {
                    Text("This site").tag("site")
                    Text("Across Bowser").tag("browser")
                }.pickerStyle(.segmented).frame(maxWidth: 270)
                Text(model.scope == "browser" ? "Browser-wide customization" : "\(URL(string: model.targetURL)?.host ?? "Open a website") · includes subdomains")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let project = model.project {
                        ForEach(project.turns) { turn in turnView(turn) }
                        if project.status == "interrupted" || project.status == "restored" {
                            Text(project.summary).font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(Color.accentColor)
                            Text("A small change.\nA browser that feels like you.")
                                .font(.system(size: 25, weight: .medium, design: .rounded))
                            Text("Describe what you want. Try it on the page, then keep refining the same mod.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            ForEach(["Hide distractions and leave only the main content", "Make this page easier to read"], id: \.self) { example in
                                Button { model.draft = example; composerFocused = true } label: {
                                    HStack { Text(example); Spacer(); Image(systemName: "arrow.up.left") }
                                        .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 25)
                    }
                    if model.project?.status == "working" {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(model.snapshot.stage).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if !model.snapshot.progress.isEmpty && model.project?.status == "working" {
                        DisclosureGroup("Activity details", isExpanded: $showDetails) {
                            Text(model.snapshot.progress.joined(separator: "\n"))
                                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.project?.turns.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.snapshot.selected) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func turnView(_ turn: ModSmithTurn) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(turn.role == "user" ? "You" : turn.role == "system" ? "Revision history" : "ModSmith")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(turn.text).font(.system(size: 13)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let notes = turn.notes, !notes.isEmpty {
                DisclosureGroup("Details and limitations") {
                    Text(notes).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            if let checks = turn.checks {
                if checks.isEmpty {
                    Text("No verification reported.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Checks reported by the agent").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                        Label(check, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(turn.role == "user" ? Color.accentColor.opacity(0.07) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.connectionError ?? model.snapshot.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            TextField(model.project == nil ? "Describe your mod…" : "What should we change next?", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...6).focused($composerFocused)
                .padding(13).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            HStack {
                Text(model.snapshot.busy ? "A change is running. You can draft the next one." : "⌘ Return to send")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.project == nil ? "Create mod" : "Refine mod", systemImage: "arrow.up") { model.submit() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.snapshot.busy || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).background(.bar)
    }
}
