import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        // Before any webview exists: embedded players need real third-party
        // cookies (bowser-browser-yll).
        EngineView.disableTrackingPrevention()
        BrainBridge.shared.start()
        openWindow()
        NSApp.activate()

        // WKWebView (as first responder) claims ⌘-key equivalents before the
        // menu ever sees them — intercept ours ahead of window dispatch.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // ⌘⇧[ / ⌘⇧] cycle tabs (Safari muscle memory; arrows would
            // collide with select-to-line-edge in text fields).
            if flags == [.command, .shift] {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "[":
                    self?.currentController?.activateAdjacentTab(offset: -1)
                    return nil
                case "]":
                    self?.currentController?.activateAdjacentTab(offset: 1)
                    return nil
                case "c":
                    self?.copyCurrentURL(nil)
                    return nil
                default:
                    return event
                }
            }
            guard flags == .command,
                  let key = event.charactersIgnoringModifiers?.lowercased()
            else { return event }
            switch key {
            case "k", "l":
                if let controller = self?.currentController {
                    CommandBar.shared.show(for: controller)
                }
                return nil
            case "r":
                self?.currentController?.activeTab?.webView.reload()
                return nil
            case "=", "+":
                self?.currentController?.activeTab?.zoom(direction: 1)
                return nil
            case "-":
                self?.currentController?.activeTab?.zoom(direction: -1)
                return nil
            case "0":
                self?.currentController?.activeTab?.zoom(direction: 0)
                return nil
            default:
                return event
            }
        }
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
    func openWindow(profile: Profile = .defaultProfile) -> BrowserWindowController {
        let isFirstWindow = BrowserWindowController.all.isEmpty
        // The controller brings its own first tab and emits tab_opened.
        let controller = BrowserWindowController(profile: profile)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        // The omnibar greets a COLD start (blank tab, nothing to show); a
        // resurrecting window is about to display the restored session and
        // the palette popping over the freeze-frame breaks the illusion
        // (bowser-browser-xl8).
        if !controller.isResurrecting { controller.focusOmnibar() }
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
        opener explicitOpener: UInt64? = nil,
        profile requestedProfile: String? = nil
    ) -> EngineView {
        // A profile was named (the brain's open_tab / a restore): the tab goes
        // to that profile's window, creating one — its first tab takes the
        // URL, so exactly one tab_opened is emitted — if there is none.
        if let requestedProfile, explicitOpener == nil {
            let target = Profile.find(requestedProfile)
            if let controller = BrowserWindowController.all.last(where: { $0.profile.id == target.id }) {
                let view = controller.openTab(configuration: configuration, opener: nil, activate: activate)
                if let url { view.load(urlString: url) }
                return view
            }
            let controller = openWindow(profile: target)
            if let url { controller.loadURL(url) }
            return controller.activeTab
        }
        let opener = explicitOpener ?? currentWebviewId
        // Popups and link-opened tabs stay in their opener's window — same
        // profile, same data store.
        let host = explicitOpener.flatMap { BrowserWindowController.host(of: $0) }
        guard let controller = host ?? currentController else {
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

    /// ⌘N: another window of the CURRENT profile.
    @objc func newWindow(_ sender: Any?) {
        openWindow(profile: currentController?.profile ?? .defaultProfile)
    }

    @objc func newWindowInProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        openWindow(profile: Profile.find(id))
    }

    private var profileMenu: NSMenu?

    /// File → New Window In ▸ one item per profile; rebuilt when the brain
    /// pushes a changed list.
    func rebuildProfileMenu() {
        guard let profileMenu else { return }
        profileMenu.removeAllItems()
        for profile in Profile.all {
            let item = NSMenuItem(title: profile.label, action: #selector(newWindowInProfile(_:)), keyEquivalent: "")
            item.representedObject = profile.id
            if let color = profile.color {
                let dot = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
                    color.setFill(); NSBezierPath(ovalIn: rect).fill(); return true
                }
                item.image = dot
            }
            profileMenu.addItem(item)
        }
        profileMenu.addItem(.separator())
        let hint = NSMenuItem(title: "New profile: type  :profile new <name> [color] [emoji]", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        profileMenu.addItem(hint)
    }

    /// ⌘W closes the TAB now; the window goes with the last one.
    @objc func closeTab(_ sender: Any?) {
        guard let controller = currentController, let view = controller.activeTab else { return }
        controller.closeTab(view)
    }

    @objc func closeWindow(_ sender: Any?) {
        currentController?.window?.close()
    }

    @objc func reloadPage(_ sender: Any?) {
        currentController?.activeTab?.webView.reload()
    }

    @objc func copyCurrentURL(_ sender: Any?) {
        guard let url = currentController?.activeTab?.currentURLString else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url, forType: .string)
    }

    @objc func previousTab(_ sender: Any?) { currentController?.activateAdjacentTab(offset: -1) }
    @objc func nextTabInOrder(_ sender: Any?) { currentController?.activateAdjacentTab(offset: 1) }

    @objc func zoomIn(_ sender: Any?) { currentController?.activeTab?.zoom(direction: 1) }
    @objc func zoomOut(_ sender: Any?) { currentController?.activeTab?.zoom(direction: -1) }
    @objc func actualSize(_ sender: Any?) { currentController?.activeTab?.zoom(direction: 0) }

    @objc private func modMenuClick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ChromeSurface.emit(["op": "event", "event": "chrome_click", "id": id])
    }

    private var viewMenu: NSMenu?
    /// Mod-owned View-menu entries (tagged so rebuilds only touch ours).
    private static let modItemTag = 777

    func rebuildModMenuItems() {
        guard let viewMenu else { return }
        while let index = viewMenu.items.firstIndex(where: { $0.tag == Self.modItemTag }) {
            viewMenu.removeItem(at: index)
        }
        guard !ChromeSurface.menuItems.isEmpty else { return }
        let separator = NSMenuItem.separator()
        separator.tag = Self.modItemTag
        viewMenu.addItem(separator)
        for item in ChromeSurface.menuItems {
            let menuItem = NSMenuItem(
                title: item.title,
                action: #selector(modMenuClick(_:)),
                keyEquivalent: item.key ?? ""
            )
            menuItem.tag = Self.modItemTag
            menuItem.representedObject = item.id
            if let checked = item.checked {
                menuItem.state = checked ? .on : .off
            }
            viewMenu.addItem(menuItem)
        }
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
        let inItem = NSMenuItem(title: "New Window In", action: nil, keyEquivalent: "")
        let inMenu = NSMenu(title: "New Window In")
        inItem.submenu = inMenu
        fileMenu.addItem(inItem)
        profileMenu = inMenu
        rebuildProfileMenu()
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

        let viewMenuItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload Page", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(actualSize(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        view.addItem(.separator())
        let fullScreen = view.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenuItem.submenu = view
        mainMenu.addItem(viewMenuItem)
        viewMenu = view
        rebuildModMenuItems()

        let goMenuItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(withTitle: "Command Bar", action: #selector(BrowserWindowController.focusOmnibarAction(_:)), keyEquivalent: "k")
        goMenu.addItem(withTitle: "Open Location", action: #selector(BrowserWindowController.focusOmnibarAction(_:)), keyEquivalent: "l")
        let copyURLItem = goMenu.addItem(
            withTitle: "Copy URL", action: #selector(copyCurrentURL(_:)), keyEquivalent: "c"
        )
        copyURLItem.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(.separator())
        let previousItem = goMenu.addItem(
            withTitle: "Previous Tab", action: #selector(previousTab(_:)), keyEquivalent: "["
        )
        previousItem.keyEquivalentModifierMask = [.command, .shift]
        let nextItem = goMenu.addItem(
            withTitle: "Next Tab", action: #selector(nextTabInOrder(_:)), keyEquivalent: "]"
        )
        nextItem.keyEquivalentModifierMask = [.command, .shift]
        goMenuItem.submenu = goMenu
        mainMenu.addItem(goMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
