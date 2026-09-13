import Combine

import AppKit
import SwiftUI
import BowserSurfaceKit

/// The host keeps models alive; renderer generations contain presentation only.
struct LiveBrowserScreen<Model: ObservableObject>: NSViewRepresentable where Model.ObjectWillChangePublisher == ObservableObjectPublisher {
    let kind: String
    let model: Model
    @MainActor final class Coordinator {
        var context: BrowserScreenContext?
        func close(_ slot: NativeModuleSlot) {
            slot.retire()
            if let context { BrowserScreenContext.contexts.removeValue(forKey: context.id) }
            context = nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context bridge: Context) -> NativeModuleSlot {
        let context = BrowserScreenContext(kind: kind, model: model)
        bridge.coordinator.context = context
        BrowserScreenContext.contexts[context.id] = context
        let fallback = NSHostingView(rootView: BrowserScreenRoot(context: context))
        fallback.sizingOptions = []
        let slot = NativeModuleSlot(fallback: fallback, kind: .surfaces)
        // Screen text editors use SwiftUI state. Defer replacement while editing
        // instead of destroying focus, selection, marked text or undo history.
        slot.interactionInProgress = { [weak slot] in
            guard let slot, let responder = slot.window?.firstResponder as? NSView else { return false }
            return responder is NSTextView && responder.isDescendant(of: slot)
        }
        slot.setSnapshot(try! JSONSerialization.data(withJSONObject: ["screen": context.id]))
        return slot
    }
    func updateNSView(_ view: NativeModuleSlot, context: Context) {}
    static func dismantleNSView(_ view: NativeModuleSlot, coordinator: Coordinator) { coordinator.close(view) }
}
