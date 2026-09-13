import AppKit
import WebKit

/// Elixir publishes declarative routing rules; WebKit gets a synchronous answer.
@MainActor final class NavigationPolicy {
    static let shared = NavigationPolicy()
    private struct Rule {
        let required: NSEvent.ModifierFlags
        let forbidden: NSEvent.ModifierFlags
        let action: EngineView.TabIntent
    }
    private var rules = [
        Rule(required: [.command, .shift], forbidden: [], action: .foregroundTab),
        Rule(required: [.command], forbidden: [], action: .backgroundTab)
    ]
    @discardableResult func update(_ values: [[String: Any]]) -> Bool {
        guard values.count <= 32 else { return false }
        var candidate: [Rule] = []
        let flags: [String: NSEvent.ModifierFlags] = ["command":.command, "shift":.shift, "option":.option, "control":.control]
        for value in values {
            guard let required = value["required"] as? [String], let forbidden = value["forbidden"] as? [String],
                  (required + forbidden).allSatisfy({ flags[$0] != nil }), Set(required).isDisjoint(with: forbidden) else { return false }
            let action: EngineView.TabIntent
            switch value["action"] as? String {
            case "same_tab": action = .sameTab
            case "background_tab": action = .backgroundTab
            case "foreground_tab": action = .foregroundTab
            default: return false
            }
            candidate.append(Rule(required: required.reduce([]) { $0.union(flags[$1]!) },
                                  forbidden: forbidden.reduce([]) { $0.union(flags[$1]!) }, action: action))
        }
        rules = candidate
        return true
    }
    func intent(type: WKNavigationType, modifiers: NSEvent.ModifierFlags) -> EngineView.TabIntent {
        guard type == .linkActivated else { return .sameTab }
        return rules.first(where: { modifiers.isSuperset(of: $0.required) && modifiers.intersection($0.forbidden).isEmpty })?.action ?? .sameTab
    }
}
