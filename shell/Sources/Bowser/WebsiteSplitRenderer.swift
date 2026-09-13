import AppKit
import BowserSurfaceKit

@MainActor enum WebsiteSplitRenderer {
    static func build(_ node: WebsiteLayoutNode, _ frame: NSRect, _ views: [UInt64: NSView]) -> NSView {
        if let id = node.webview {
            let view = views[id]!
            view.removeFromSuperview(); view.frame = frame
            return view
        }
        return WebsiteSplit(frame: frame, node: node, children: node.children.map { build($0, frame, views) })
    }
}

@MainActor
final class WebsiteSplit: NSSplitView, NSSplitViewDelegate, WebsiteSplitSnapshot {
    let node: WebsiteLayoutNode
    let panes: [NSView]
    override var dividerThickness: CGFloat {
        guard panes.count > 1 else { return 0 }
        return min(1, max(0, (isVertical ? bounds.width : bounds.height) / CGFloat(panes.count)))
    }
    var fractions: [Double] {
        let sizes = panes.map { isVertical ? $0.frame.width : $0.frame.height }
        let total = sizes.reduce(0, +)
        return sizes.map { total > 0 ? Double($0 / total) : 1 / Double(panes.count) }
    }
    var snapshot: [String: Any] {
        var json = node.json
        let weights = fractions
        json["children"] = zip(node.children, panes).enumerated().map { index, pair in
            var child = (pair.1 as? any WebsiteSplitSnapshot)?.snapshot ?? pair.0.json
            child["weight"] = max(weights[index], Double.leastNormalMagnitude)
            return child
        }
        return json
    }
    init(frame: NSRect, node: WebsiteLayoutNode, children: [NSView]) {
        self.node = node
        panes = children
        super.init(frame: frame)
        isVertical = node.type == "row"
        dividerStyle = .thin
        delegate = self
        autoresizingMask = [.width, .height]
        for child in children { addSubview(child) }
        arrange(node.children.map(\.weight))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func resizeSubviews(withOldSize oldSize: NSSize) { arrange(fractions) }
    override func mouseDown(with event: NSEvent) { if node.resizable { super.mouseDown(with: event) } }
    override func resetCursorRects() { if node.resizable { super.resetCursorRects() } }
    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        if node.resizable { super.setPosition(position, ofDividerAt: dividerIndex) }
    }

    func arrange(_ weights: [Double]) {
        let length = isVertical ? bounds.width : bounds.height
        let available = max(0, length - dividerThickness * CGFloat(panes.count - 1))
        let minima = node.children.map { isVertical ? $0.minimumSize.width : $0.minimumSize.height }
        let sizes = Self.allocate(available: available, weights: weights, minima: minima)
        var position: CGFloat = 0
        for (index, pane) in panes.enumerated() {
            pane.frame = isVertical ? NSRect(x: position, y: 0, width: sizes[index], height: bounds.height)
                : NSRect(x: 0, y: position, width: bounds.width, height: sizes[index])
            position += sizes[index] + dividerThickness
        }
    }
    /// Weighted allocation with minimum constraints. If the window cannot fit
    /// all minima, compress proportionally rather than producing negative sizes.
    static func allocate(available: CGFloat, weights: [Double], minima: [CGFloat]) -> [CGFloat] {
        let totalMinimum = minima.reduce(0, +)
        if totalMinimum >= available, totalMinimum > 0 { return minima.map { available * ($0 / totalMinimum) } }
        var result = Array(repeating: CGFloat(0), count: weights.count)
        var pending = Array(weights.indices)
        var remaining = available
        while !pending.isEmpty {
            let scale = pending.map { weights[$0] }.max() ?? 1
            let total = pending.reduce(0.0) { $0 + weights[$1] / scale }
            let constrained = pending.filter { remaining * CGFloat((weights[$0] / scale) / total) < minima[$0] }
            if constrained.isEmpty {
                for i in pending { result[i] = remaining * CGFloat((weights[i] / scale) / total) }
                break
            }
            for i in constrained { result[i] = minima[i]; remaining -= minima[i] }
            pending.removeAll { constrained.contains($0) }
        }
        return result
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        let pane = panes[index]
        return (isVertical ? pane.frame.minX : pane.frame.minY) + effectiveMinimum(index)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        let pane = panes[index + 1]
        return (isVertical ? pane.frame.maxX : pane.frame.maxY) - effectiveMinimum(index + 1) - dividerThickness
    }
    private func effectiveMinimum(_ index: Int) -> CGFloat {
        let minimum = node.children[index].minimumSize
        let actual = isVertical ? panes[index].frame.width : panes[index].frame.height
        return min(actual, isVertical ? minimum.width : minimum.height)
    }
}
