import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [BrowserWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        BrainBridge.shared.start()
        openWindow(asTab: false)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @discardableResult
    func openWindow(asTab: Bool) -> BrowserWindowController {
        let controller = BrowserWindowController()
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.controllers.removeAll { $0 === controller }
        }
        if asTab, let keyWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            keyWindow.addTabbedWindow(controller.window!, ordered: .above)
        }
        let isFirstWindow = controllers.isEmpty
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusOmnibar()
        // Restore fullscreen for the primary window after a respawn.
        if isFirstWindow, !asTab, UserDefaults.standard.bool(forKey: "BowserWasFullscreen") {
            DispatchQueue.main.async { [weak controller] in
                controller?.window?.toggleFullScreen(nil)
            }
        }
        return controller
    }

    @objc func newTab(_ sender: Any?) {
        openWindow(asTab: true)
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(asTab: false)
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
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        goMenu.addItem(withTitle: "Open Location", action: #selector(BrowserWindowController.focusOmnibarAction(_:)), keyEquivalent: "l")
        goMenuItem.submenu = goMenu
        mainMenu.addItem(goMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
