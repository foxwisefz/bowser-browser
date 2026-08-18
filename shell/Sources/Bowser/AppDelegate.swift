import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        BrainBridge.shared.start()
        openWindow()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// The window that owns new tabs: the key/main browser window, else the
    /// most recent one. Panels (command bar, mod surfaces) are never it —
    /// that mistake is what used to make the command bar a tab host.
    var currentController: BrowserWindowController? {
        let focused = [NSApp.keyWindow, NSApp.mainWindow]
            .compactMap { $0?.windowController as? BrowserWindowController }
            .first
        return focused ?? BrowserWindowController.all.last
    }

    /// The webview the user is looking at — the opener for anything they open.
    var currentWebviewId: UInt64? { currentController?.activeTab?.webviewId }

    @discardableResult
    func openWindow() -> BrowserWindowController {
        let isFirstWindow = BrowserWindowController.all.isEmpty
        // The controller brings its own first tab and emits tab_opened.
        let controller = BrowserWindowController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusOmnibar()
        // Restore fullscreen for the primary window after a respawn.
        if isFirstWindow, UserDefaults.standard.bool(forKey: "BowserWasFullscreen") {
            DispatchQueue.main.async { [weak controller] in
                controller?.window?.toggleFullScreen(nil)
            }
        }
        return controller
    }

    /// Open a tab in the current window, creating a window if there is none.
    /// `activate: false` leaves it detached in memory — nothing on screen
    /// moves, and the dock picks it up from the tab_opened event.
    @discardableResult
    func openTab(
        url: String? = nil,
        activate: Bool = true,
        configuration: WKWebViewConfiguration? = nil,
        opener explicitOpener: UInt64? = nil
    ) -> EngineView {
        let opener = explicitOpener ?? currentWebviewId
        guard let controller = currentController else {
            let controller = openWindow()
            if let url { controller.loadURL(url) }
            return controller.activeTab
        }
        let view = controller.openTab(
            configuration: configuration, opener: opener, activate: activate
        )
        if let url { view.load(urlString: url) }
        return view
    }

    /// ⌘T: a new webview, switched to at once, omnibar up. No tab group is
    /// created and no tab bar appears — there is no native tabbing left.
    @objc func newTab(_ sender: Any?) {
        guard let controller = currentController else {
            openWindow()
            return
        }
        controller.openTab(opener: controller.activeTab?.webviewId, activate: true)
        controller.focusOmnibar()
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow()
    }

    /// ⌘W closes the TAB now; the window goes with the last one.
    @objc func closeTab(_ sender: Any?) {
        guard let controller = currentController, let view = controller.activeTab else { return }
        controller.closeTab(view)
    }

    @objc func closeWindow(_ sender: Any?) {
        currentController?.window?.close()
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Bowser", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        let closeWindowItem = fileMenu.addItem(
            withTitle: "Close Window", action: #selector(closeWindow(_:)), keyEquivalent: "w"
        )
        closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let goMenuItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(withTitle: "Command Bar", action: #selector(BrowserWindowController.focusOmnibarAction(_:)), keyEquivalent: "k")
        goMenu.addItem(withTitle: "Open Location", action: #selector(BrowserWindowController.focusOmnibarAction(_:)), keyEquivalent: "l")
        goMenuItem.submenu = goMenu
        mainMenu.addItem(goMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
