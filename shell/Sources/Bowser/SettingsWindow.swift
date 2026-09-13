import AppKit
import SwiftUI

/// Native macOS preferences toolbar. Built-in panes own their UI; mods
/// can still register additional settings sections through the surface API.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = SettingsWindow()

    typealias Section = SettingsSection

    final class Model: ObservableObject, SettingsPresentation {
        lazy var permissionsContext = BrowserScreenContext(kind: "permissions", model: PermissionSettingsModel.shared)
        lazy var profilesContext = BrowserScreenContext(kind: "profiles", model: ProfileSettingsModel.shared)
        lazy var defaultContext = BrowserScreenContext(kind: "default-browser", model: DefaultBrowserSettingsModel.shared)

        @Published var sections: [Section] = [Section(id: "websites", title: "Websites", order: 30, tree: [:])]
        @Published var selected: String?
        /// Bumped on every tree update so the detail re-renders (trees are
        /// [String: Any], not Equatable).
        @Published var revision = 0
    }

    let model = Model()
    private var window: NSWindow?
    private var preferencesToolbar: NSToolbar?

    /// Sidebar order: by `order`, then title — pure, tested.
    nonisolated static func ordered(_ sections: [Section]) -> [Section] {
        sections.sorted { ($0.order, $0.title) < ($1.order, $1.title) }
    }

    func set(id: String, title: String, order: Int, tree: [String: Any]) {
        if id == "profiles" { ProfileSettingsModel.shared.notice = tree["status"] as? String }
        var sections = model.sections.filter { $0.id != id }
        sections.append(Section(id: id, title: title, order: order, tree: tree))
        model.sections = Self.ordered(sections)
        if model.selected == nil || !model.sections.contains(where: { $0.id == model.selected }) {
            model.selected = model.sections.first?.id
        }
        model.revision += 1
        refreshToolbar()
    }

    func remove(id: String) {
        model.sections.removeAll { $0.id == id }
        if model.selected == id { model.selected = model.sections.first?.id }
        model.revision += 1
        refreshToolbar()
    }

    /// Open (or front) the window; `select` picks a section. Tells the brain
    /// so every section re-renders fresh.
    func show(select id: String? = nil) {
        NativeUIHost.shared.state.settingsChanged = { [weak self] in
            guard let self, let toolbar = self.preferencesToolbar else { return }
            while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
            self.refreshToolbar()
        }
        PermissionSettingsModel.shared.start()
        DefaultBrowserSettingsModel.shared.refresh()
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Settings"
            w.toolbarStyle = .preference
            let toolbar = NSToolbar(identifier: "BowserPreferences")
            toolbar.delegate = self
            toolbar.displayMode = .iconAndLabel
            toolbar.allowsUserCustomization = false
            w.toolbar = toolbar
            preferencesToolbar = toolbar
            w.isReleasedWhenClosed = false
            w.tabbingMode = .disallowed
            w.minSize = NSSize(width: 760, height: 600)
            w.center()
            w.setFrameAutosaveName("BowserSettingsWindow")
            let content = NSHostingView(rootView: LiveBrowserScreen(kind: "settings", model: model))
            content.sizingOptions = []
            w.contentView = content
            w.delegate = self
            window = w
        }
        if let id, id != model.selected, ProfileSettingsModel.shared.confirmDiscardChanges() { model.selected = id }
        refreshToolbar()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        BrainBridge.shared.send(["op": "event", "event": "settings_opened"])
    }

    private var toolbarIdentifiers: [NSToolbarItem.Identifier] {
        model.sections.map { NSToolbarItem.Identifier($0.id) }
    }

    private func refreshToolbar() {
        guard let toolbar = preferencesToolbar else { return }
        let identifiers = toolbarIdentifiers
        if toolbar.items.map(\.itemIdentifier) != identifiers {
            while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
            for (index, id) in identifiers.enumerated() { toolbar.insertItem(withItemIdentifier: id, at: index) }
        }
        toolbar.selectedItemIdentifier = model.selected.map { NSToolbarItem.Identifier($0) }
        window?.title = model.sections.first { $0.id == model.selected }?.title ?? "Settings"
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarIdentifiers }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarIdentifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarIdentifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let section = model.sections.first(where: { $0.id == id.rawValue }) else { return nil }
        return NativeUIHost.shared.state.settingsItem?(section, self)
    }

    @objc private func selectToolbarSection(_ sender: NSToolbarItem) {
        if sender.itemIdentifier.rawValue != model.selected, ProfileSettingsModel.shared.confirmDiscardChanges() {
            model.selected = sender.itemIdentifier.rawValue
        }
        refreshToolbar()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        ProfileSettingsModel.shared.confirmDiscardChanges()
    }

}

@MainActor
final class DefaultBrowserSettingsModel: ObservableObject, DefaultBrowserPresentation {
    var isDefault: Bool { status == .isDefault }
    static let shared = DefaultBrowserSettingsModel()

    enum Status: Equatable {
        case unavailable
        case checking
        case notDefault
        case partial
        case isDefault
        case failed(String)
    }

    @Published private(set) var status: Status = .checking
    @Published private(set) var isSetting = false

    static func status(httpIsBowser: Bool, httpsIsBowser: Bool) -> Status {
        switch (httpIsBowser, httpsIsBowser) {
        case (true, true): .isDefault
        case (false, false): .notDefault
        default: .partial
        }
    }

    var canSetDefault: Bool {
        Self.isInstalledApplication(Bundle.main) && !isSetting
    }

    var statusText: String {
        switch status {
        case .unavailable: "Open the installed Bowser.app to change this setting."
        case .checking: "Checking the macOS default browser…"
        case .notDefault: "Bowser is not your default browser."
        case .partial: "Bowser handles only some web links."
        case .isDefault: "Bowser is your default browser."
        case .failed(let message): message
        }
    }

    func refresh() {
        guard Self.isInstalledApplication(Bundle.main) else {
            status = .unavailable
            return
        }
        guard !isSetting else { return }
        status = .checking
        status = Self.status(
            httpIsBowser: Self.isBowserHandler(for: URL(string: "http://example.com")!),
            httpsIsBowser: Self.isBowserHandler(for: URL(string: "https://example.com")!)
        )
    }

    func setDefault() {
        guard canSetDefault else { return }
        isSetting = true
        Task {
            do {
                for scheme in ["http", "https"] {
                    try await NSWorkspace.shared.setDefaultApplication(
                        at: Bundle.main.bundleURL,
                        toOpenURLsWithScheme: scheme
                    )
                }
                isSetting = false
                refresh()
            } catch {
                isSetting = false
                status = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated static func isInstalledApplication(_ bundle: Bundle) -> Bool {
        bundle.bundleIdentifier == "com.foxwiseai.bowser" && bundle.bundleURL.pathExtension == "app"
    }

    private static func isBowserHandler(for url: URL) -> Bool {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url),
              let bundle = Bundle(url: applicationURL)
        else { return false }
        return bundle.bundleIdentifier == "com.foxwiseai.bowser"
    }
}

