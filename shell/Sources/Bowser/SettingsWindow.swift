import AppKit
import SwiftUI

/// The conventional Settings window (⌘,): a sidebar of sections, each one a
/// brain-rendered view tree shown with kind :settings — General (declared
/// settings), Profiles, Mods, and whatever a mod adds. Same tree renderer
/// and event routing as floating panels, so the brain-side handlers do not
/// change; only where the UI lives does.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    struct Section: Identifiable, Equatable {
        let id: String
        var title: String
        var order: Int
        var tree: [String: Any]

        static func == (a: Section, b: Section) -> Bool {
            a.id == b.id && a.title == b.title && a.order == b.order
        }
    }

    final class Model: ObservableObject {
        @Published var sections: [Section] = []
        @Published var selected: String?
        /// Bumped on every tree update so the detail re-renders (trees are
        /// [String: Any], not Equatable).
        @Published var revision = 0
    }

    let model = Model()
    private var window: NSWindow?

    /// Sidebar order: by `order`, then title — pure, tested.
    nonisolated static func ordered(_ sections: [Section]) -> [Section] {
        sections.sorted { ($0.order, $0.title) < ($1.order, $1.title) }
    }

    func set(id: String, title: String, order: Int, tree: [String: Any]) {
        var sections = model.sections.filter { $0.id != id }
        sections.append(Section(id: id, title: title, order: order, tree: tree))
        model.sections = Self.ordered(sections)
        if model.selected == nil || !model.sections.contains(where: { $0.id == model.selected }) {
            model.selected = model.sections.first?.id
        }
        model.revision += 1
    }

    func remove(id: String) {
        model.sections.removeAll { $0.id == id }
        if model.selected == id { model.selected = model.sections.first?.id }
        model.revision += 1
    }

    /// Open (or front) the window; `select` picks a section. Tells the brain
    /// so every section re-renders fresh.
    func show(select id: String? = nil) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            w.tabbingMode = .disallowed
            w.minSize = NSSize(width: 620, height: 400)
            w.center()
            w.setFrameAutosaveName("BowserSettingsWindow")
            w.contentView = NSHostingView(rootView: SettingsRootView(model: model))
            w.delegate = self
            window = w
        }
        if let id { model.selected = id }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        BrainBridge.shared.send(["op": "event", "event": "settings_opened"])
    }
}

struct SettingsRootView: View {
    @ObservedObject var model: SettingsWindow.Model

    var body: some View {
        NavigationSplitView {
            List(model.sections, selection: $model.selected) { section in
                Text(section.title).tag(section.id)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            if let section = model.sections.first(where: { $0.id == model.selected }) {
                ScrollView {
                    SurfaceTreeView(surfaceId: section.id, node: section.tree)
                        .id("\(section.id)-\(model.revision)")
                        .padding(22)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(section.title)
            } else {
                Text("No settings sections yet — the brain is still connecting.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
