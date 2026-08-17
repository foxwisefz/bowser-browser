import AppKit
import CBowserHost
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
    private static var controllers: [ObjectIdentifier: BrowserWindowController] = [:]

    static func register(_ controller: BrowserWindowController) {
        controllers[ObjectIdentifier(controller)] = controller
        controller.syncModButtons()
    }

    static func unregister(_ controller: BrowserWindowController) {
        controllers.removeValue(forKey: ObjectIdentifier(controller))
    }

    static func handle(_ json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["chrome"] as? String
        else {
            NSLog("Bowser: unparseable chrome op")
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
        default:
            NSLog("Bowser: unknown chrome op \(action)")
            return
        }
        for controller in controllers.values {
            controller.syncModButtons()
        }
    }

    static func emit(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8)
        else { return }
        json.withCString { bowser_emit_event($0) }
    }
}

// File-scope C trampoline (see swift6-c-callback-trap). Fires during
// bowser_brain_pump on the main thread; string is copied before the hop.
func bowserChromeOp(_ ctx: UnsafeMutableRawPointer?, _ value: UnsafePointer<CChar>?) {
    guard let value else { return }
    let json = String(cString: value)
    MainActor.assumeIsolated { ChromeSurface.handle(json) }
}
