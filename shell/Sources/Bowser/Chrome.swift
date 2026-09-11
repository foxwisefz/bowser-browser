import AppKit
import Foundation

/// Mod-driven chrome surface points (Mod API v1): the brain sends "chrome"
/// ops, the shell applies them to every browser window. State lives here so
/// windows created later inherit the current surface.
@MainActor
enum ChromeSurface {
    struct ModButton: Equatable {
        let id: String
        let title: String
        let symbol: String?
    }

    struct ModMenuItem: Equatable {
        let id: String
        let title: String
        let key: String?
        /// nil = plain action item; true/false = stateful toggle with checkmark.
        let checked: Bool?
    }

    private static var profileButtons: [String: [ModButton]] = [:]
    private static var profileMenus: [String: [ModMenuItem]] = [:]
    private static var profileThemes: [String: ShellTheme] = [:]
    private static var profileToolbars: [String: [ModToolbar]] = [:]
    private static var profileCommands: [String: [String: String]] = [:]
    static func buttons(for profile: String) -> [ModButton] { buttons + (profileButtons[profile] ?? []) }
    static func menus(for profile: String) -> [ModMenuItem] { menuItems + (profileMenus[profile] ?? []) }
    static func theme(for profile: String) -> ShellTheme { profileThemes[profile] ?? theme }
    static func toolbars(for profile: String) -> [ModToolbar] { toolbars + (profileToolbars[profile] ?? []) }
    static func commands(for profile: String) -> [String: String] { commands.merging(profileCommands[profile] ?? [:]) { _, new in new } }

    private(set) static var buttons: [ModButton] = []
    /// Mod-owned entries appended to the native View menu; clicks come back
    /// as chrome_click, exactly like band buttons.
    private(set) static var menuItems: [ModMenuItem] = []
    /// Registered omnibar commands: name → hint (shown while typing).
    private(set) static var commands: [String: String] = [:]
    private(set) static var theme: ShellTheme = .native
    private(set) static var toolbars: [ModToolbar] = []
    private static var controllers: [ObjectIdentifier: BrowserWindowController] = [:]

    static func register(_ controller: BrowserWindowController) {
        controllers[ObjectIdentifier(controller)] = controller
        controller.syncModButtons()
        controller.syncShellTheme()
        controller.syncToolbars()
    }

    static func unregister(_ controller: BrowserWindowController) {
        controllers.removeValue(forKey: ObjectIdentifier(controller))
    }

    static func handle(_ object: [String: Any]) {
        guard let action = object["chrome"] as? String else {
            NSLog("Bowser: chrome op without action")
            return
        }

        let profile = object["profile"] as? String
        switch action {
        case "set_toolbars":
            guard let json = object["toolbars"] as? [[String: Any]], json.count <= 16 else { return }
            let parsed = json.compactMap(ModToolbar.init(json:))
            guard parsed.count == json.count, Set(parsed.map(\.id)).count == parsed.count else { return }
            if let profile { profileToolbars[profile] = parsed } else { toolbars = parsed }
            for controller in controllers.values { controller.syncToolbars() }
            return
        case "set_theme":
            guard let json = object["theme"] as? [String: Any],
                  let next = ShellTheme(json: json) else { return }
            if let profile { profileThemes[profile] = next } else { theme = next }
            for controller in controllers.values { controller.syncShellTheme() }
            return
        case "add_button":
            guard let id = object["id"] as? String else { return }
            var entries = profile.map { profileButtons[$0] ?? [] } ?? buttons
            entries.removeAll { $0.id == id }
            entries.append(ModButton(
                id: id,
                title: object["title"] as? String ?? id,
                symbol: object["symbol"] as? String
            ))
        if let profile { profileButtons[profile] = entries } else { buttons = entries }
        case "remove_button":
            guard let id = object["id"] as? String else { return }
            if let profile { profileButtons[profile]?.removeAll { $0.id == id } } else { buttons.removeAll { $0.id == id } }
        case "add_menu_item":
            guard let id = object["id"] as? String else { return }
            var entries = profile.map { profileMenus[$0] ?? [] } ?? menuItems
            entries.removeAll { $0.id == id }
            entries.append(ModMenuItem(
                id: id,
                title: object["title"] as? String ?? id,
                key: object["key"] as? String,
                checked: object["checked"] as? Bool
            ))
            if let profile { profileMenus[profile] = entries } else { menuItems = entries }
            // NSApplication.shared, not NSApp: NSApp is nil in headless tests.
            (NSApplication.shared.delegate as? AppDelegate)?.rebuildModMenuItems()
            return
        case "remove_menu_item":
            guard let id = object["id"] as? String else { return }
            if let profile { profileMenus[profile]?.removeAll { $0.id == id } } else { menuItems.removeAll { $0.id == id } }
            (NSApplication.shared.delegate as? AppDelegate)?.rebuildModMenuItems()
            return
        case "register_command":
            guard let name = object["name"] as? String else { return }
            if let profile { profileCommands[profile, default: [:]][name] = object["hint"] as? String ?? name }
            else { commands[name] = object["hint"] as? String ?? name }
            return
        case "hide_tab_bar", "show_tab_bar":
            // Accepted and ignored: there IS no native tab bar any more
            // (bowser-browser-cdd). Mods written against the old API — the
            // dock calls hide_tab_bar on every hello — must not break.
            return
        case "open_tab":
            guard let delegate = NSApp.delegate as? AppDelegate else { return }
            // Background by default: open_tab creates the webview, the dock
            // (or an explicit activate_tab) decides what the user sees.
            delegate.openTab(
                url: object["url"] as? String,
                activate: object["activate"] as? Bool ?? false,
                profile: object["profile"] as? String
            )
            return
        case "open_window":
            guard let delegate = NSApp.delegate as? AppDelegate else { return }
            let controller = delegate.openWindow(profile: Profile.find(object["profile"] as? String))
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        default:
            NSLog("Bowser: unknown chrome op \(action)")
            return
        }
        for controller in controllers.values {
            controller.syncModButtons()
        }
    }

    static func emit(_ message: [String: Any]) {
        BrainBridge.shared.send(message)
    }
}
