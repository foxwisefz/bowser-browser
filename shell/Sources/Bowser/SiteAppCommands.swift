import AppKit

/// Saved apps offer actions on their own page, not a second browser launcher.
@MainActor
final class SiteAppCommands: NSObject {
    static let shared = SiteAppCommands()
    enum Action: String, CaseIterable {
        case reload = "Reload"
        case back = "Back"
        case forward = "Forward"
        case copyLink = "Copy Link"
        case openInBowser = "Open in Bowser"
    }
    private var panel: SiteAppCommandPanel?
    private weak var target: BrowserWindowController?

    func show(for controller: BrowserWindowController) {
        guard let window = controller.window else { return }
        target = controller
        let panel = self.panel ?? SiteAppCommandPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 245),
            styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        self.panel = panel
        panel.title = SiteAppConfiguration.current?.url.host ?? "App Actions"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        for action in Action.allCases {
            let button = NSButton(title: action.rawValue, target: self, action: #selector(run(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            button.bezelStyle = .rounded
            if action == .back { button.isEnabled = controller.activeTab.webView.canGoBack }
            if action == .forward { button.isEnabled = controller.activeTab.webView.canGoForward }
            stack.addArrangedSubview(button)
        }
        panel.contentView = stack
        panel.setFrameOrigin(NSPoint(x: window.frame.midX - 170, y: window.frame.midY - 80))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func run(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let action = Action(rawValue: value), let target else { return }
        panel?.orderOut(nil)
        switch action {
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

private final class SiteAppCommandPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func resignKey() { super.resignKey(); orderOut(nil) }
}
