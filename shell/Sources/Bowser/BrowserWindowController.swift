import AppKit
import WebKit

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTextFieldDelegate {
    private(set) var engineView: EngineView!
    private let omnibar = NSTextField()
    private let commandHint = NSTextField(labelWithString: "")
    var onClose: (() -> Void)?

    convenience init(configuration: WKWebViewConfiguration? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Come back where the user left us, across crash/upgrade respawns.
        if let saved = UserDefaults.standard.string(forKey: "BowserWindowFrame") {
            window.setFrame(NSRectFromString(saved), display: false)
        } else {
            window.center()
        }
        window.title = "Bowser"
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "bowser-browser"
        self.init(window: window)

        engineView = EngineView(frame: .zero, configuration: configuration)
        window.delegate = self
        window.contentView = engineView

        omnibar.placeholderString = "Search, address, or :command"
        omnibar.delegate = self
        omnibar.target = self
        omnibar.action = #selector(omnibarSubmitted(_:))
        omnibar.bezelStyle = .roundedBezel
        omnibar.font = .systemFont(ofSize: 13)

        commandHint.font = .systemFont(ofSize: 10, weight: .semibold)
        commandHint.textColor = .secondaryLabelColor
        commandHint.isHidden = true
        commandHint.translatesAutoresizingMaskIntoConstraints = false
        omnibar.addSubview(commandHint)
        NSLayoutConstraint.activate([
            commandHint.trailingAnchor.constraint(equalTo: omnibar.trailingAnchor, constant: -8),
            commandHint.centerYAnchor.constraint(equalTo: omnibar.centerYAnchor),
        ])

        let toolbar = NSToolbar(identifier: "bowser-toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none

        engineView.onTitleChange = { [weak window] title in
            window?.title = title.isEmpty ? "Bowser" : title
        }
        engineView.onURLChange = { [weak self] url in
            guard let self else { return }
            // Never clobber what the user is typing: while the omnibar has an
            // active field editor, page-driven URL updates are dropped.
            if self.omnibar.currentEditor() == nil {
                self.omnibar.stringValue = url
                self.updateOmnibarMode()
            }
        }

        ChromeSurface.register(self)
    }

    func focusOmnibar() {
        window?.makeFirstResponder(omnibar)
    }

    func loadURL(_ url: String) {
        engineView.load(urlString: url)
    }

    @objc func focusOmnibarAction(_ sender: Any?) {
        focusOmnibar()
    }

    @objc private func omnibarSubmitted(_ sender: Any?) {
        let text = omnibar.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // ":command args" goes to the brain, not the web.
        if text.hasPrefix(":") {
            ChromeSurface.emit([
                "op": "event", "event": "omnibar_command",
                "text": String(text.dropFirst()),
            ])
            window?.makeFirstResponder(engineView)
            return
        }
        engineView.load(urlString: Self.normalize(text))
        window?.makeFirstResponder(engineView)
    }

    // MARK: Command-mode recognition

    func controlTextDidChange(_ obj: Notification) {
        updateOmnibarMode()
    }

    private func updateOmnibarMode() {
        let text = omnibar.stringValue

        guard text.hasPrefix(":") else {
            omnibar.font = .systemFont(ofSize: 13)
            omnibar.textColor = .textColor
            styleEditor(font: .systemFont(ofSize: 13), color: .textColor)
            commandHint.isHidden = true
            return
        }

        let name = text.dropFirst().split(separator: " ").first.map(String.init) ?? ""
        let hint: String
        if name.isEmpty {
            hint = "command"
        } else if let registered = ChromeSurface.commands[name] {
            hint = registered
        } else {
            let candidates = ChromeSurface.commands.keys
                .filter { $0.hasPrefix(name) }.sorted()
            hint = candidates.isEmpty ? "unknown command" : candidates.joined(separator: " · ")
        }

        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium)
        omnibar.font = font
        omnibar.textColor = .controlAccentColor
        styleEditor(font: font, color: .controlAccentColor)
        commandHint.stringValue = hint
        commandHint.isHidden = false
    }

    private func styleEditor(font: NSFont, color: NSColor) {
        guard let editor = omnibar.currentEditor() as? NSTextView else { return }
        editor.font = font
        editor.textColor = color
    }

    // Bare words search; things that look like URLs get https://.
    static func normalize(_ input: String) -> String {
        if input.contains("://") { return input }
        if input.contains(".") && !input.contains(" ") { return "https://\(input)" }
        let query = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
        return "https://duckduckgo.com/?q=\(query)"
    }

    func windowWillClose(_ notification: Notification) {
        ChromeSurface.unregister(self)
        engineView.tearDown()
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        BrainBridge.shared.send([
            "op": "event", "event": "tab_activated", "webview": engineView.webviewId,
        ])
    }

    private func persistWindowState() {
        guard let window else { return }
        if !window.styleMask.contains(.fullScreen) {
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "BowserWindowFrame")
        }
    }

    func windowDidMove(_ notification: Notification) { persistWindowState() }
    func windowDidEndLiveResize(_ notification: Notification) { persistWindowState() }

    func windowDidEnterFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "BowserWasFullscreen")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "BowserWasFullscreen")
    }

    // MARK: NSToolbarDelegate

    private static let omnibarItemID = NSToolbarItem.Identifier("omnibar")
    private static let backItemID = NSToolbarItem.Identifier("back")
    private static let forwardItemID = NSToolbarItem.Identifier("forward")

    private static let modPrefix = "mod."

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.backItemID, Self.forwardItemID, .flexibleSpace, Self.omnibarItemID, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
            + ChromeSurface.buttons.map { NSToolbarItem.Identifier(Self.modPrefix + $0.id) }
    }

    /// Reconcile toolbar mod buttons with ChromeSurface.buttons (append-at-end).
    func syncModButtons() {
        guard let toolbar = window?.toolbar else { return }
        let wanted = ChromeSurface.buttons.map { NSToolbarItem.Identifier(Self.modPrefix + $0.id) }

        for (index, item) in toolbar.items.enumerated().reversed()
        where item.itemIdentifier.rawValue.hasPrefix(Self.modPrefix)
            && !wanted.contains(item.itemIdentifier) {
            toolbar.removeItem(at: index)
        }
        let present = toolbar.items.map(\.itemIdentifier)
        for identifier in wanted where !present.contains(identifier) {
            toolbar.insertItem(withItemIdentifier: identifier, at: toolbar.items.count)
            NSLog("Bowser: toolbar mod button inserted: \(identifier.rawValue)")
        }
    }

    @objc private func modButtonClicked(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        ChromeSurface.emit(["op": "event", "event": "chrome_click", "id": id])
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
            let raw = itemIdentifier.rawValue
            guard raw.hasPrefix(Self.modPrefix) else { return nil }
            let modID = String(raw.dropFirst(Self.modPrefix.count))
            guard let spec = ChromeSurface.buttons.first(where: { $0.id == modID }) else {
                return nil
            }
            let button = NSButton(title: spec.title, target: self, action: #selector(modButtonClicked(_:)))
            button.bezelStyle = .texturedRounded
            if let symbol = spec.symbol,
               let image = NSImage(systemSymbolName: symbol, accessibilityDescription: spec.title) {
                button.image = image
                button.imagePosition = spec.title.isEmpty ? .imageOnly : .imageLeading
            }
            button.identifier = NSUserInterfaceItemIdentifier(modID)
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = spec.title
            return item
        }
    }
}
