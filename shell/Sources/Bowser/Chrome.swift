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

    private(set) static var buttons: [ModButton] = []
    /// Mod-owned entries appended to the native View menu; clicks come back
    /// as chrome_click, exactly like band buttons.
    private(set) static var menuItems: [ModMenuItem] = []
    /// Registered omnibar commands: name → hint (shown while typing).
    private(set) static var commands: [String: String] = [:]
    private static var controllers: [ObjectIdentifier: BrowserWindowController] = [:]

    static func register(_ controller: BrowserWindowController) {
        controllers[ObjectIdentifier(controller)] = controller
        controller.syncModButtons()
    }

    static func unregister(_ controller: BrowserWindowController) {
        controllers.removeValue(forKey: ObjectIdentifier(controller))
    }

    static func handle(_ object: [String: Any]) {
        guard let action = object["chrome"] as? String else {
            NSLog("Bowser: chrome op without action")
            return
        }

        switch action {
        case "add_button":
            guard let id = object["id"] as? String else { return }
            buttons.removeAll { $0.id == id }
            buttons.append(ModButton(
                id: id,
                title: object["title"] as? String ?? id,
                symbol: object["symbol"] as? String
            ))
        case "remove_button":
            guard let id = object["id"] as? String else { return }
            buttons.removeAll { $0.id == id }
        case "add_menu_item":
            guard let id = object["id"] as? String else { return }
            menuItems.removeAll { $0.id == id }
            menuItems.append(ModMenuItem(
                id: id,
                title: object["title"] as? String ?? id,
                key: object["key"] as? String,
                checked: object["checked"] as? Bool
            ))
            // NSApplication.shared, not NSApp: NSApp is nil in headless tests.
            (NSApplication.shared.delegate as? AppDelegate)?.rebuildModMenuItems()
            return
        case "remove_menu_item":
            guard let id = object["id"] as? String else { return }
            menuItems.removeAll { $0.id == id }
            (NSApplication.shared.delegate as? AppDelegate)?.rebuildModMenuItems()
            return
        case "register_command":
            guard let name = object["name"] as? String else { return }
            commands[name] = object["hint"] as? String ?? name
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
