import AppKit
import SwiftUI

struct ModToolbar {
    let id: String
    let edge: String
    let size: CGFloat
    let view: [String: Any]
    let style: [String: Any]

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty, id.utf8.count <= 100,
              let edge = json["edge"] as? String, ["top", "bottom", "left", "right"].contains(edge),
              let size = json["size"] as? NSNumber, CFGetTypeID(size) != CFBooleanGetTypeID(),
              size.doubleValue.isFinite, (16...(edge == "left" || edge == "right" ? 800.0 : 200.0)).contains(size.doubleValue),
              let view = json["view"] as? [String: Any],
              let style = (json["style"] ?? [:]) as? [String: Any], SurfaceColorSpec.validStyle(style) else { return nil }
        self.id = id; self.edge = edge; self.size = size.doubleValue
        self.view = view; self.style = style
    }
}

/// AppKit owns the page frame; no DOM transforms or injected CSS are involved.
struct ToolbarFrames {
    var page: NSRect
    var bars: [String: NSRect]

    static func calculate(bounds: NSRect, bars: [ModToolbar], border: CGFloat, topInset: CGFloat) -> Self {
        let inset = min(border, min(bounds.width, bounds.height) / 2)
        var area = bounds.insetBy(dx: inset, dy: inset)
        // Native top bar already reserves this space inside EngineView.
        area.size.height = max(0, area.height - max(0, topInset - inset))
        var frames: [String: NSRect] = [:]
        let vertical = bars.filter { ["top", "bottom"].contains($0.edge) }.reduce(0) { $0 + $1.size }
        let horizontal = bars.filter { ["left", "right"].contains($0.edge) }.reduce(0) { $0 + $1.size }
        let yScale = vertical == 0 ? 1 : min(1, max(0, area.height - 100) / vertical)
        let xScale = horizontal == 0 ? 1 : min(1, max(0, area.width - 100) / horizontal)
        // Horizontal bars span the window; side bars fill the remaining middle.
        for bar in bars.sorted(by: { a, b in
            let aRank = ["top", "bottom"].contains(a.edge) ? 0 : 1
            let bRank = ["top", "bottom"].contains(b.edge) ? 0 : 1
            return (aRank, a.id) < (bRank, b.id)
        }) {
            var frame = area
            let size = bar.size * (["top", "bottom"].contains(bar.edge) ? yScale : xScale)
            switch bar.edge {
            case "top": frame.origin.y = area.maxY - size; frame.size.height = size; area.size.height -= size
            case "bottom": frame.size.height = size; area.origin.y += size; area.size.height -= size
            case "left": frame.size.width = size; area.origin.x += size; area.size.width -= size
            default: frame.origin.x = area.maxX - size; frame.size.width = size; area.size.width -= size
            }
            frames[bar.id] = frame
        }
        // EngineView's existing top inset makes its content start below the
        // native band plus added top bars. Preserve that contract.
        area.size.height += min(topInset, max(0, bounds.maxY - area.maxY))
        return Self(page: area, bars: frames)
    }
}

@MainActor
final class ToolbarContainerView: NSView {
    let pageArea = NSView()
    private var hosts: [String: NSHostingView<AnyView>] = [:]
    private var bars: [ModToolbar] = []
    private let stateNamespace = UUID().uuidString
    private let outline = WindowBorderView()
    var webview: UInt64 = 0 { didSet { refreshRoots() } }
    var theme: ShellTheme = .native { didSet { outline.theme = theme; needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(pageArea)
        addSubview(outline)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func setBars(_ bars: [ModToolbar]) {
        self.bars = bars
        let ids = Set(bars.map(\.id))
        for id in Array(hosts.keys) where !ids.contains(id) {
            hosts.removeValue(forKey: id)?.removeFromSuperview()
            SurfaceFormStore.shared.remove(surface: stateNamespace + "|toolbar:" + id)
        }
        refreshRoots()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    func releaseLocalState() {
        for id in hosts.keys { SurfaceFormStore.shared.remove(surface: stateNamespace + "|toolbar:" + id) }
    }
    private func refreshRoots() {
        for bar in bars {
            let root = AnyView(ModToolbarView(bar: bar, webview: webview)
                .modifier(SurfacePaletteScope(palette: bar.style["palette"] as? [String: Any]))
                .environment(\.surfaceStateNamespace, stateNamespace))
            if let host = hosts[bar.id] { host.rootView = root }
            else {
                let host = NSHostingView(rootView: root)
                hosts[bar.id] = host
                addSubview(host, positioned: .below, relativeTo: outline)
            }
        }
    }
    override func layout() {
        super.layout()
        if subviews.last !== outline { addSubview(outline, positioned: .above, relativeTo: nil) }
        let frames = ToolbarFrames.calculate(bounds: bounds, bars: bars, border: theme.windowBorderWidth, topInset: EngineView.pageTopInset)
        pageArea.frame = frames.page
        for (id, host) in hosts { host.frame = frames.bars[id] ?? .zero }
        outline.frame = bounds
        // Detached tabs also receive the correct size when next mounted.
    }
}

final class WindowBorderView: NSView {
    var theme: ShellTheme = .native { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let width = theme.windowBorderWidth
        guard width > 0 else { return }
        let color = theme.color("window_border") ?? .separatorColor
        let path = NSBezierPath(rect: bounds.insetBy(dx: width / 2, dy: width / 2))
        path.lineWidth = width; color.setStroke(); path.stroke()
        if theme.windowBorderStyle == "beveled" {
            let light = NSBezierPath()
            light.move(to: NSPoint(x: width / 2, y: width / 2))
            light.line(to: NSPoint(x: width / 2, y: bounds.maxY - width / 2))
            light.line(to: NSPoint(x: bounds.maxX - width / 2, y: bounds.maxY - width / 2))
            light.lineWidth = width / 2
            (color.blended(withFraction: 0.6, of: .white) ?? .white).setStroke(); light.stroke()
        }
    }
}
