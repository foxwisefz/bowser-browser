import AppKit

/// Saved apps offer actions on their own page, not a second browser launcher.
@MainActor
final class SiteAppCommands: NSObject {
    static let shared = SiteAppCommands()
    enum Action: String, CaseIterable {
        case createMod = "Create Mod…"
        case reload = "Reload"
        case back = "Back"
        case forward = "Forward"
        case copyLink = "Copy Link"
        case openInBowser = "Open in Bowser"
    }
    private var modPanel: NSPanel?
    private var requestField: NSTextField?
    private var statusLabel: NSTextField?
    private weak var target: BrowserWindowController?

    private func showModBuilder() {
        guard let window = target?.window else { return }
        if let modPanel { modPanel.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Create App Mod"
        panel.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let hint = NSTextField(wrappingLabelWithString: "Describe a change for this app. It will apply only here.")
        stack.addArrangedSubview(hint)
        let field = NSTextField()
        field.placeholderString = "e.g. Hide the sidebar and use larger text"
        field.target = self
        field.action = #selector(submitMod)
        field.widthAnchor.constraint(equalToConstant: 420).isActive = true
        stack.addArrangedSubview(field)
        let button = NSButton(title: "Create Mod", target: self, action: #selector(submitMod))
        button.bezelStyle = .rounded
        stack.addArrangedSubview(button)
        let status = NSTextField(wrappingLabelWithString: "Ready")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.widthAnchor.constraint(equalToConstant: 420).isActive = true
        stack.addArrangedSubview(status)
        panel.contentView = stack
        panel.setFrameOrigin(NSPoint(x: window.frame.midX - 230, y: window.frame.midY - 115))
        modPanel = panel
        requestField = field
        statusLabel = status
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    @objc private func submitMod() {
        let request = requestField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !request.isEmpty else { return }
        guard BrainBridge.shared.isConnected else {
            updateStatus("Connecting to Bowser. Try again shortly.")
            return
        }
        updateStatus("Working on your app mod…")
        BrainBridge.shared.send(["op": "event", "event": "site_mod_request", "request": request])
    }

    func updateStatus(_ text: String) {
        statusLabel?.stringValue = String(text.suffix(300))
    }

    @objc func runMenuAction(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let action = Action(rawValue: value),
              let target = (NSApp.delegate as? AppDelegate)?.currentController else { return }
        self.target = target
        switch action {
        case .createMod: showModBuilder()
        case .reload: target.activeTab.webView.reload()
        case .back: target.activeTab.webView.goBack()
        case .forward: target.activeTab.webView.goForward()
        case .copyLink:
            if let url = target.activeTab.webView.url {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        case .openInBowser:
            guard let url = target.activeTab.webView.url, let config = SiteAppConfiguration.current else { return }
            NSWorkspace.shared.open([url], withApplicationAt: config.mainApp, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
