import AppKit

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTextFieldDelegate {
    private let engineView = EngineView()
    private let omnibar = NSTextField()
    var onClose: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Bowser"
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "bowser-browser"
        self.init(window: window)

        window.delegate = self
        window.contentView = engineView

        omnibar.placeholderString = "Search or enter address"
        omnibar.delegate = self
        omnibar.target = self
        omnibar.action = #selector(omnibarSubmitted(_:))
        omnibar.bezelStyle = .roundedBezel
        omnibar.font = .systemFont(ofSize: 13)

        let toolbar = NSToolbar(identifier: "bowser-toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        engineView.onTitleChange = { [weak window] title in
            window?.title = title.isEmpty ? "Bowser" : title
        }
        engineView.onURLChange = { [weak self] url in
            self?.omnibar.stringValue = url
        }
    }

    func focusOmnibar() {
        window?.makeFirstResponder(omnibar)
    }

    @objc func focusOmnibarAction(_ sender: Any?) {
        focusOmnibar()
    }

    @objc private func omnibarSubmitted(_ sender: Any?) {
        let text = omnibar.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        engineView.load(urlString: Self.normalize(text))
        window?.makeFirstResponder(engineView)
    }

    // Bare words search; things that look like URLs get https://.
    static func normalize(_ input: String) -> String {
        if input.contains("://") { return input }
        if input.contains(".") && !input.contains(" ") { return "https://\(input)" }
        let query = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
        return "https://duckduckgo.com/?q=\(query)"
    }

    func windowWillClose(_ notification: Notification) {
        engineView.tearDown()
        onClose?()
    }

    // MARK: NSToolbarDelegate

    private static let omnibarItemID = NSToolbarItem.Identifier("omnibar")
    private static let backItemID = NSToolbarItem.Identifier("back")
    private static let forwardItemID = NSToolbarItem.Identifier("forward")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.backItemID, Self.forwardItemID, .flexibleSpace, Self.omnibarItemID, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.omnibarItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = omnibar
            item.visibilityPriority = .high
            omnibar.translatesAutoresizingMaskIntoConstraints = false
            omnibar.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
            return item
        case Self.backItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
            item.target = engineView
            item.action = #selector(EngineView.goBack(_:))
            return item
        case Self.forwardItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
            item.target = engineView
            item.action = #selector(EngineView.goForward(_:))
            return item
        default:
            return nil
        }
    }
}
