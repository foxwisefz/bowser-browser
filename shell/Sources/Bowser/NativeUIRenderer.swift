import AppKit
import BowserSurfaceKit

/// Installs presentation functions only after the loader commits a generation.
@MainActor final class NativeUIRenderer: NSView, BrowserScreenActivating {
    private let model: NativeUIState
    init(state: NativeUIState) { model = state; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(state:)") }
    func activateScreen() {
        model.profileMenu = NativeUIPresentation.profileMenu
        model.modMenu = NativeUIPresentation.modMenu
        model.settingsItem = NativeUIPresentation.settingsItem
        model.settingsChanged()
        model.menus = NativeUIPresentation.menus
        model.alert = NativeUIPresentation.alert
        model.layout = WebsiteSplitRenderer.build
        model.layoutChanged()
        model.changed()
    }
}
@MainActor enum NativeUIPresentation {
    static func menus(_ context: NativeMenuContext) -> NativeMenus {
        var profileMenu: NSMenu?
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        if context.siteHost == nil {
            appMenu.addItem(withTitle: "Settings…", action: NSSelectorFromString("openSettings:"), keyEquivalent: ",")
            let updates = appMenu.addItem(withTitle: "Check for Updates…", action: NSSelectorFromString("checkForUpdates:"), keyEquivalent: "")
            updates.target = context.targets["updates"]
        }
        appMenu.addItem(.separator())
        if context.siteHost != nil {
            let item = appMenu.addItem(withTitle: "Reset Website Notification Permissions…", action: NSSelectorFromString("resetPermissions:"), keyEquivalent: "")
            item.target = context.targets["notifications"]
        }
        appMenu.addItem(withTitle: "Quit " + (context.siteHost ?? "Bowser"), action: NSSelectorFromString("terminate:"), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        if context.siteHost != nil {
            fileMenu.addItem(withTitle: "Close Window", action: NSSelectorFromString("closeWindow:"), keyEquivalent: "w")
        } else {
        fileMenu.addItem(withTitle: "New Tab", action: NSSelectorFromString("newTab:"), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Open File…", action: NSSelectorFromString("openFile:"), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "New Window", action: NSSelectorFromString("newWindow:"), keyEquivalent: "n")
        let inItem = NSMenuItem(title: "New Window In", action: nil, keyEquivalent: "")
        let inMenu = NSMenu(title: "New Window In")
        inItem.submenu = inMenu
        fileMenu.addItem(inItem)
        profileMenu = inMenu

        fileMenu.addItem(withTitle: "Close Tab", action: NSSelectorFromString("closeTab:"), keyEquivalent: "w")
        let closeWindowItem = fileMenu.addItem(
            withTitle: "Close Window", action: NSSelectorFromString("closeWindow:"), keyEquivalent: "w"
        )
        closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
        }
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let view = NSMenu(title: "View")
        let modsmith = NSMenuItem(title: "ModSmith…", action: NSSelectorFromString("open:"), keyEquivalent: "")
        modsmith.target = context.targets["modsmith"]
        view.addItem(modsmith)
        let permissions = view.addItem(withTitle: "Website Permissions…", action: NSSelectorFromString("show:"), keyEquivalent: "")
        permissions.target = context.targets["permissions"]
        view.addItem(.separator())
        view.addItem(withTitle: "Reload Page", action: NSSelectorFromString("reloadPage:"), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: NSSelectorFromString("actualSize:"), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom In", action: NSSelectorFromString("zoomIn:"), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: NSSelectorFromString("zoomOut:"), keyEquivalent: "-")
        view.addItem(.separator())
        let fullScreen = view.addItem(
            withTitle: "Enter Full Screen",
            action: NSSelectorFromString("toggleFullScreen:"),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        let pip = view.addItem(withTitle: "Picture in Picture", action: NSSelectorFromString("togglePictureInPicture:"), keyEquivalent: "p")
        pip.target = context.target
        pip.keyEquivalentModifierMask = [.command, .option]
        viewMenuItem.submenu = view
        mainMenu.addItem(viewMenuItem)


        let goMenuItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        if context.siteHost == nil {
            goMenu.addItem(withTitle: "Command Bar", action: NSSelectorFromString("focusOmnibarAction:"), keyEquivalent: "k")
            goMenu.addItem(withTitle: "Open Location", action: NSSelectorFromString("focusOmnibarAction:"), keyEquivalent: "l")
        }
        let copyURLItem = goMenu.addItem(
            withTitle: "Copy URL", action: NSSelectorFromString("copyCurrentURL:"), keyEquivalent: "c"
        )
        copyURLItem.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(.separator())
        if context.siteHost == nil {
        let previousItem = goMenu.addItem(
            withTitle: "Previous Tab", action: NSSelectorFromString("previousTab:"), keyEquivalent: "["
        )
        previousItem.keyEquivalentModifierMask = [.command, .shift]
        let nextItem = goMenu.addItem(
            withTitle: "Next Tab", action: NSSelectorFromString("nextTabInOrder:"), keyEquivalent: "]"
        )
        nextItem.keyEquivalentModifierMask = [.command, .shift]
        }
        if context.siteHost != nil {
            for action in context.siteActions {
                let item = goMenu.addItem(withTitle: action, action: NSSelectorFromString("runMenuAction:"), keyEquivalent: "")
                item.target = context.targets["siteCommands"]
                item.representedObject = action
            }
        }
        goMenuItem.submenu = goMenu
        mainMenu.addItem(goMenuItem)

        // A real Window menu: Minimize/Zoom, cycling, and AppKit's own list
        // of open windows (one per profile, typically) via windowsMenu.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: NSSelectorFromString("performMiniaturize:"), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: NSSelectorFromString("performZoom:"), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Cycle Through Windows", action: NSSelectorFromString("cycleWindowsForward:"), keyEquivalent: "`")
        let back = windowMenu.addItem(withTitle: "Cycle Back Through Windows", action: NSSelectorFromString("cycleWindowsBackward:"), keyEquivalent: "`")
        back.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(.separator())
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        return NativeMenus(main: mainMenu, windows: windowMenu, profiles: profileMenu, mods: view)
    }
    static func alert(_ kind: String, _ values: [String: String]) -> NSAlert {
        let alert = NSAlert()
        let title: String, detail: String, buttons: [String]
        switch kind {
        case "media-permission":
            title = "Allow \(values["devices"] ?? "media") access?"
            detail = "\(values["origin"] ?? "This site") wants to use your \(values["devices"] ?? "devices")."
            buttons = ["Allow Once", "Always Allow", "Block", "Cancel"]
        case "external":
            let name = values["name"] ?? "application"
            title = "Open \(name)?"; detail = "\(values["source"] ?? "This website") wants to open a link in \(name)."
            buttons = ["Cancel", "Open"]
        case "profile-discard":
            title = "Discard unsaved profile changes?"; detail = "Your changes to this profile haven’t been saved."
            buttons = ["Discard Changes", "Keep Editing"]
        case "backend-start":
            title = "Bowser couldn’t start its backend"; detail = "Tabs and mods need the backend. Details are in \(values["log"] ?? "brain.log")."
            buttons = ["Retry", "Quit Bowser"]
        case "pip-unavailable":
            title = "Picture in Picture unavailable"
            detail = "Play a supported video on this page, then try again. Videos in some embedded players may need their own Picture in Picture control."
            buttons = ["OK"]
        case "notification-reset":
            title = "Reset website notification permissions?"
            detail = "Websites in this app will ask again. macOS notification settings remain in System Settings."
            buttons = ["Reset", "Cancel"]
        case "notification-permission":
            title = "Allow notifications from \(values["origin"] ?? "this website")?"
            detail = "This website can send notifications while this app is running. You can turn them off in Notification Settings."
            buttons = ["Allow", "Don't Allow"]
        case "update-available":
            title = "Bowser \(values["version"] ?? "") is available"
            detail = "Download now? The update will activate after Bowser and its saved apps quit."
            buttons = ["Download Update", "Later"]
        default: title = values["text"] ?? "Bowser"; detail = ""; buttons = ["OK"]
        }
        alert.messageText = title; alert.informativeText = detail
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert
    }
}

@MainActor extension NativeUIPresentation {
    static func profileMenu(_ menu: NSMenu, _ entries: [[String: Any]]) {
        menu.removeAllItems()
        for entry in entries {
            let item = NSMenuItem(title: entry["label"] as? String ?? "", action: NSSelectorFromString("newWindowInProfile:"), keyEquivalent: "")
            item.representedObject = entry["id"]
            if let image = (entry["portrait"] as? NSImage)?.copy() as? NSImage {
                image.size = NSSize(width: 20, height: 20); item.image = image
            } else if let color = entry["color"] as? NSColor {
                item.image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
                    color.setFill(); NSBezierPath(ovalIn: rect).fill(); return true
                }
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "New Profile…", action: NSSelectorFromString("showProfiles"), keyEquivalent: ""))
    }
    static func modMenu(_ menu: NSMenu, _ entries: [[String: Any]]) {
        for item in menu.items where item.tag == 777 { menu.removeItem(item) }
        guard !entries.isEmpty else { return }
        let separator = NSMenuItem.separator(); separator.tag = 777; menu.addItem(separator)
        for entry in entries {
            let item = NSMenuItem(title: entry["title"] as? String ?? "", action: NSSelectorFromString("modMenuClick:"), keyEquivalent: entry["key"] as? String ?? "")
            item.tag = 777; item.representedObject = entry["id"]
            if let checked = entry["checked"] as? Bool { item.state = checked ? .on : .off }
            menu.addItem(item)
        }
    }
    static func settingsItem(_ section: SettingsSection, _ target: NSObject) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(section.id))
        item.label = section.title; item.paletteLabel = section.title
        let symbol = ["websites": "globe", "settings": "gearshape", "profiles": "person.crop.rectangle", "mods": "puzzlepiece.extension"][section.id] ?? "slider.horizontal.3"
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: section.title)
        item.target = target; item.action = NSSelectorFromString("selectToolbarSection:")
        return item
    }
}
