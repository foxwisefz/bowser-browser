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
        NSLog("Bowser: controls action=\(selectorName) window=\(window.windowNumber) miniaturizable=\(window.styleMask.contains(.miniaturizable)) beforeMini=\(window.isMiniaturized)")
        switch self {
        case .close:
            window.performClose(nil)
        case .minimize:
            window.miniaturize(nil)
        case .zoom:
            window.performZoom(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak window] in
            guard let window else { return }
            NSLog("Bowser: controls result=\(self.selectorName) window=\(window.windowNumber) afterMini=\(window.isMiniaturized) visible=\(window.isVisible)")
        }
    }
}
