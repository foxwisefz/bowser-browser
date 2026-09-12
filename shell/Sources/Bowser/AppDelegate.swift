import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var siteTerminationObserver: NSObjectProtocol?
    private var didFinishLaunching = false
    private(set) var isTerminating = false
    private var pendingExternalURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        SurfaceHostServices.configure()
        didFinishLaunching = true
        Task {
            let receipt = try? RegistrationStore(directory: BowserPaths.home).load()
            await Telemetry.shared.start(token: receipt?.telemetryToken)
        }
        if SiteAppConfiguration.current != nil { SiteAppNotifications.shared.start() }
        buildMenu()
        AppUpdates.shared.start()
        // Before any webview exists: embedded players need real third-party
        // cookies (bowser-browser-yll).
        EngineView.disableTrackingPrevention()
        BrainBridge.shared.start()
        BackendLifecycle.shared.start()
        if let configuration = SiteAppConfiguration.current {
            let controller = BrowserWindowController(profile: Profile.find(configuration.profile))
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.restoreFullscreen()
            SiteAppRuntime.shared.start(configuration, controller: controller)
        } else if pendingExternalURLs.isEmpty {
            openWindow()
        } else {
            let urls = pendingExternalURLs
            pendingExternalURLs.removeAll()
            openExternalURLs(urls)
        }
        if SiteAppConfiguration.current == nil {
            SiteAppHub.shared.start()
            TabAppBundle.upgradeSavedApps()
            siteTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier?.hasPrefix("com.foxwiseai.bowser.site.") == true else { return }
                MainActor.assumeIsolated { TabAppBundle.upgradeSavedApps() }
            }
        }
        NSApp.activate()

        // WKWebView (as first responder) claims ⌘-key equivalents before the
        // menu ever sees them — intercept ours ahead of window dispatch.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // ⌘` / ⌘⇧` by PHYSICAL key (kVK_ANSI_Grave): the typed character
            // for that key varies by layout, and a miss here beeps.
            if event.keyCode == 50 || event.keyCode == 10, flags == .command || flags == [.command, .shift] {
                self?.cycleWindows(forward: flags == .command)
                return nil
            }
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
                case "`", "~":
                    self?.cycleWindows(forward: false)
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
                guard SiteAppConfiguration.current == nil else { return event }
                if let controller = self?.currentController {
                    CommandBar.shared.show(for: controller)
                }
                return nil
            case "r":
                self?.currentController?.activeTab?.webView.reload()
                return nil
            case ",":
                self?.openSettings(nil)
                return nil
            case "`":
                self?.cycleWindows(forward: true)
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
        SiteAppConfiguration.current != nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        return BackendLifecycle.shared.quit()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let urls = Self.webURLs(from: urls)
        guard !urls.isEmpty else { return }
        guard didFinishLaunching else {
            pendingExternalURLs.append(contentsOf: urls)
            return
        }
        openExternalURLs(urls)
        application.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard SiteAppConfiguration.current != nil else {
            if BrowserWindowController.all.isEmpty { openWindow() }
            return true
        }
        currentController?.window?.deminiaturize(nil)
        currentController?.window?.makeKeyAndOrderFront(nil)
        return false
    }

    nonisolated static func webURLs(from urls: [URL]) -> [URL] {
        urls.filter { url in
            guard let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https" || url.isFileURL
        }
    }

    @objc func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.openExternalURLs(panel.urls)
        }
    }

    private func openExternalURLs(_ urls: [URL]) {
        for url in urls {
            openTab(url: url.absoluteString)
        }
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
    func openWindow(profile requested: Profile? = nil) -> BrowserWindowController {
        let profile = SiteAppConfiguration.current.map { Profile.find($0.profile) } ?? requested ?? Profile.main
        let isFirstWindowForProfile = !BrowserWindowController.all.contains { $0.profile.id == profile.id }
        // The controller brings its own first tab and emits tab_opened.
        let controller = BrowserWindowController(profile: profile)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        // The omnibar greets a COLD start (blank tab, nothing to show); a
        // resurrecting window is about to display the restored session and
        // the palette popping over the freeze-frame breaks the illusion
        // (bowser-browser-xl8).
        if !controller.isResurrecting { controller.focusOmnibar() }
        if isFirstWindowForProfile { controller.restoreFullscreen() }
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
        profile requestedProfile: String? = nil,
        append: Bool = false
    ) -> EngineView {
        if let site = SiteAppConfiguration.current {
            // App popups get visible windows, never hidden tabs with no strip.
            let controller = openWindow(profile: Profile.find(site.profile))
            if let url { controller.loadURL(url) }
            return controller.activeTab
        }
        // A profile was named (the brain's open_tab / a restore): the tab goes
        // to that profile's window, creating one — its first tab takes the
        // URL, so exactly one tab_opened is emitted — if there is none.
        if let requestedProfile, explicitOpener == nil {
            let target = Profile.find(requestedProfile)
            if let controller = BrowserWindowController.all.last(where: { $0.profile.id == target.id }) {
                let view = controller.openTab(configuration: configuration, opener: nil, activate: activate, append: append)
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
            configuration: configuration, opener: opener, activate: activate, append: append
        )
        if let url { view.load(urlString: url) }
        return view
    }

    /// ⌘T: a new webview, switched to at once, omnibar up. No tab group is
    /// created and no tab bar appears — there is no native tabbing left.
    @objc func newTab(_ sender: Any?) {
        if SiteAppConfiguration.current != nil { return }
        guard let controller = currentController else {
            openWindow()
            return
        }
        controller.openTab(opener: controller.activeTab?.webviewId, activate: true)
        controller.focusOmnibar()
    }

    /// ⌘N: another window of the CURRENT profile.
    /// ⌘` / ⌘⇧`: cycle browser windows (one per profile, typically) the way
    /// macOS does — the front window goes to the back, so repeated presses
    /// visit every window instead of ping-ponging between two.
    @objc func cycleWindowsForward(_ sender: Any?) { cycleWindows(forward: true) }
    @objc func cycleWindowsBackward(_ sender: Any?) { cycleWindows(forward: false) }

    func cycleWindows(forward: Bool) {
        let windows = NSApp.orderedWindows.filter { $0.windowController is BrowserWindowController && $0.isVisible }
        guard windows.count > 1 else { return }
        let front = windows[0]
        let next = windows[Self.nextWindowIndex(count: windows.count, forward: forward)]
        next.makeKeyAndOrderFront(nil)
        if forward { front.orderBack(nil) }
    }

    /// Index (in front-to-back order) of the window to bring forward:
    /// forward = the one right behind the front window; backward = the
    /// back-most. Pure — tested.
    nonisolated static func nextWindowIndex(count: Int, forward: Bool) -> Int {
        guard count > 1 else { return 0 }
        return forward ? 1 : count - 1
    }

    /// ⌘,: the conventional Settings window.
    @objc func openSettings(_ sender: Any?) {
        guard SiteAppConfiguration.current == nil else { return }
        SettingsWindow.shared.show()
    }

    @objc func newWindow(_ sender: Any?) {
        if SiteAppConfiguration.current != nil { currentController?.window?.makeKeyAndOrderFront(nil); return }
        openWindow(profile: currentController?.profile ?? Profile.main)
    }

    @objc func newWindowInProfile(_ sender: NSMenuItem) {
        guard SiteAppConfiguration.current == nil else { return }
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
            if let portrait = profile.avatar?.image?.copy() as? NSImage {
                portrait.size = NSSize(width: 20, height: 20)
                item.image = portrait
            } else if let color = profile.color {
                let dot = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
                    color.setFill(); NSBezierPath(ovalIn: rect).fill(); return true
                }
                item.image = dot
            }
            profileMenu.addItem(item)
        }
        profileMenu.addItem(.separator())
        profileMenu.addItem(NSMenuItem(title: "New Profile…", action: #selector(showProfiles), keyEquivalent: ""))
    }

    @objc func showProfiles() {
        let model = ProfileSettingsModel.shared
        guard model.confirmDiscardChanges() else { return }
        SettingsWindow.shared.show(select: "profiles")
        model.clearError()
        model.isPresentingCreate = true
    }

    /// ⌘W closes the TAB now; the window goes with the last one. When the
    /// key window is not a browser window (Settings, a panel), ⌘W closes
    /// THAT — not a tab in some browser window behind it.
    @objc func closeTab(_ sender: Any?) {
        if let key = NSApp.keyWindow, !(key.windowController is BrowserWindowController),
           !(key is NSPanel) || key.styleMask.contains(.closable) {
            key.performClose(nil)
            return
        }
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

    @objc func togglePictureInPicture(_ sender: Any?) {
        guard let engine = currentController?.activeTab else { return }
        PictureInPicture.toggle(engine)
    }

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
        let items = ChromeSurface.menus(for: currentController?.profile.id ?? "default")
        guard !items.isEmpty else { return }
        let separator = NSMenuItem.separator()
        separator.tag = Self.modItemTag
        viewMenu.addItem(separator)
        for item in items {
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
        if SiteAppConfiguration.current == nil {
            appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
            let updates = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppUpdates.checkForUpdates(_:)), keyEquivalent: "")
            updates.target = AppUpdates.shared
        }
        appMenu.addItem(.separator())
        if SiteAppConfiguration.current != nil {
            let item = appMenu.addItem(withTitle: "Reset Website Notification Permissions…", action: #selector(SiteAppNotifications.resetPermissions(_:)), keyEquivalent: "")
            item.target = SiteAppNotifications.shared
        }
        appMenu.addItem(withTitle: "Quit " + (SiteAppConfiguration.current?.url.host ?? "Bowser"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        if SiteAppConfiguration.current != nil {
            fileMenu.addItem(withTitle: "Close Window", action: #selector(closeWindow(_:)), keyEquivalent: "w")
        } else {
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Open File…", action: #selector(openFile(_:)), keyEquivalent: "o")
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
        }
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
        let modsmith = NSMenuItem(title: "ModSmith…", action: #selector(ModSmithWindow.open(_:)), keyEquivalent: "")
        modsmith.target = ModSmithWindow.shared
        view.addItem(modsmith)
        view.addItem(.separator())
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
        let pip = view.addItem(withTitle: "Picture in Picture", action: #selector(togglePictureInPicture(_:)), keyEquivalent: "p")
        pip.target = self
        pip.keyEquivalentModifierMask = [.command, .option]
        viewMenuItem.submenu = view
        mainMenu.addItem(viewMenuItem)
        viewMenu = view
        rebuildModMenuItems()

        let goMenuItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        if SiteAppConfiguration.current == nil {
            goMenu.addItem(withTitle: "Command Bar", action: #selector(BrowserWindowController.focusOmnibarAction(_:)), keyEquivalent: "k")
            goMenu.addItem(withTitle: "Open Location", action: #selector(BrowserWindowController.focusOmnibarAction(_:)), keyEquivalent: "l")
        }
        let copyURLItem = goMenu.addItem(
            withTitle: "Copy URL", action: #selector(copyCurrentURL(_:)), keyEquivalent: "c"
        )
        copyURLItem.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(.separator())
        if SiteAppConfiguration.current == nil {
        let previousItem = goMenu.addItem(
            withTitle: "Previous Tab", action: #selector(previousTab(_:)), keyEquivalent: "["
        )
        previousItem.keyEquivalentModifierMask = [.command, .shift]
        let nextItem = goMenu.addItem(
            withTitle: "Next Tab", action: #selector(nextTabInOrder(_:)), keyEquivalent: "]"
        )
        nextItem.keyEquivalentModifierMask = [.command, .shift]
        }
        if SiteAppConfiguration.current != nil {
            for action in [SiteAppCommands.Action.back, .forward, .openInBowser, .createMod] {
                let item = goMenu.addItem(withTitle: action.rawValue, action: #selector(SiteAppCommands.runMenuAction(_:)), keyEquivalent: "")
                item.target = SiteAppCommands.shared
                item.representedObject = action.rawValue
            }
        }
        goMenuItem.submenu = goMenu
        mainMenu.addItem(goMenuItem)

        // A real Window menu: Minimize/Zoom, cycling, and AppKit's own list
        // of open windows (one per profile, typically) via windowsMenu.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Cycle Through Windows", action: #selector(cycleWindowsForward(_:)), keyEquivalent: "`")
        let back = windowMenu.addItem(withTitle: "Cycle Back Through Windows", action: #selector(cycleWindowsBackward(_:)), keyEquivalent: "`")
        back.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(.separator())
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
