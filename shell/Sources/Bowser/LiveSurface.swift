import AppKit
import SwiftUI
import BowserSurfaceKit

/// SwiftUI owns root placement; the slot owns the replaceable rendering view.
struct LiveSurfaceTree: NSViewRepresentable {
    let surfaceId: String
    let node: [String: Any]
    var cursor: CursorModel? = nil
    var eventWebview: UInt64? = nil
    var title: String? = nil
    var style: [String: Any] = [:]
    @Environment(\.surfacePalette) private var palette
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.surfaceStateNamespace) private var namespace
    @Environment(\.surfaceEventWebview) private var inheritedWebview
    @Environment(\.surfaceDispatch) private var dispatch

    @MainActor final class Coordinator {
        var context: SurfaceRenderContext?
        var slot: NativeModuleSlot?
        var fallback: NSHostingView<SurfaceGenerationRoot>?
        var dispatch: @MainActor ([String: Any]) -> Void = { _ in }
        func close() {
            slot?.retire()
            if let context { SurfaceRenderContext.contexts.removeValue(forKey: context.id) }
            context = nil; slot = nil; fallback = nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context bridge: Context) -> NativeModuleSlot {
        let coordinator = bridge.coordinator
        let context = SurfaceRenderContext(surfaceID: surfaceId, node: node, cursor: cursor)
        context.eventWebview = eventWebview ?? inheritedWebview
        context.title = title; context.namespace = namespace
        context.palette = palette; context.style = style; context.scheme = scheme; context.contrast = contrast
        SurfaceRenderContext.contexts[context.id] = context
        coordinator.context = context; coordinator.dispatch = dispatch
        let fallback = NSHostingView(rootView: SurfaceGenerationRoot(context: context) { [weak coordinator] message in
            guard coordinator?.slot?.build == nil else { return }
            coordinator?.dispatch(message)
        })
        let slot = NativeModuleSlot(fallback: fallback, kind: .surfaces)
        coordinator.fallback = fallback; coordinator.slot = slot
        slot.onAction = { [weak coordinator] text in
            guard let data = text.data(using: .utf8), data.count <= 1_048_576,
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  message["surface"] as? String == coordinator?.context?.surfaceID else { return }
            coordinator?.dispatch(message)
        }
        slot.onGenerationChange = { [weak context] generation in
            guard let context else { return }
            context.generation = generation
            SurfaceEditorMount.activate(owner: context.id)
        }
        slot.interactionInProgress = { TabDragPreview.shared.source != nil }
        slot.setSnapshot(try! JSONSerialization.data(withJSONObject: ["context": context.id]))
        return slot
    }
    func updateNSView(_ view: NativeModuleSlot, context bridge: Context) {
        let coordinator = bridge.coordinator
        coordinator.dispatch = dispatch
        guard let context = coordinator.context else { return }
        context.eventWebview = eventWebview ?? inheritedWebview
        context.title = title; context.namespace = namespace
        context.palette = palette; context.style = style; context.scheme = scheme; context.contrast = contrast
        // Publishing the tree refreshes both fallback and active render roots.
        view.appearance = NSAppearance(named: contrast == .increased
            ? (scheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (scheme == .dark ? .darkAqua : .aqua))
        context.node = node
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeModuleSlot, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        if let height = proposal.height { return CGSize(width: width, height: height) }
        guard let content = nsView.subviews.last else { return nil }
        content.setFrameSize(CGSize(width: width, height: content.frame.height))
        return CGSize(width: width, height: content.fittingSize.height)
    }
    static func dismantleNSView(_ view: NativeModuleSlot, coordinator: Coordinator) { coordinator.close() }
}
