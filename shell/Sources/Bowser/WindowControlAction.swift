import AppKit

/// AppKit responder actions used by the custom traffic lights.
enum WindowControlAction: CaseIterable {
    case close
    case minimize
    case zoom

    nonisolated var selectorName: String {
        switch self {
        case .close: "performClose:"
        case .minimize: "performMiniaturize:"
        case .zoom: "performZoom:"
        }
    }

    nonisolated var selector: Selector { Selector(selectorName) }

    @MainActor
    func perform(on window: NSWindow) {
        switch self {
        case .close:
            window.performClose(nil)
        case .minimize:
            window.miniaturize(nil)
        case .zoom:
            window.performZoom(nil)
        }
    }
}
