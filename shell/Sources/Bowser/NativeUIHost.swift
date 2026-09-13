import AppKit
import BowserSurfaceKit

@MainActor final class NativeUIHost {
    static let shared = NativeUIHost()
    let state = NativeUIState()
    private let context: BrowserScreenContext
    private let slot: NativeModuleSlot
    private init() {
        context = BrowserScreenContext(kind: "native-ui", model: state)
        BrowserScreenContext.contexts[context.id] = context
        slot = NativeModuleSlot(fallback: NativeUIRenderer(state: state), kind: .surfaces)
        slot.setSnapshot(try! JSONSerialization.data(withJSONObject: ["screen": context.id]))
    }
    static func alert(_ kind: String, _ values: [String: String] = [:]) -> NSAlert {
        shared.state.alert?(kind, values) ?? NativeUIPresentation.alert(kind, values)
    }
}
