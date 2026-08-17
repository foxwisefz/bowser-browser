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

    private(set) static var buttons: [ModButton] = []
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
        case "register_command":
            guard let name = object["name"] as? String else { return }
            commands[name] = object["hint"] as? String ?? name
            return
        case "open_tab":
            guard let delegate = NSApp.delegate as? AppDelegate else { return }
            let controller = delegate.openWindow(asTab: true)
            if let url = object["url"] as? String {
                controller.loadURL(url)
            }
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
