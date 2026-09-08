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
    private weak var target: BrowserWindowController?

    private func showModBuilder() { ModSmithWindow.shared.open() }

    func updateStatus(_ text: String) { ModSmithWindow.shared.model.connectionError = text }

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
