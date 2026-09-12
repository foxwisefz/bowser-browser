import AppKit

/// A mod-controlled row or column of live website views.
@MainActor
final class WebsiteLayout: NSSplitView, NSSplitViewDelegate {
    let views: [EngineView]
    var ids: [UInt64] { views.map(\.webviewId) }
    var fractions: [Double] {
        let sizes = views.map { isVertical ? $0.frame.width : $0.frame.height }
        let total = sizes.reduce(0, +)
        return sizes.map { total > 0 ? Double($0 / total) : 1 / Double(views.count) }
    }

    init(frame: NSRect, views: [EngineView], axis: String, weights: [Double]) {
        self.views = views
        super.init(frame: frame)
        isVertical = axis == "horizontal"
        dividerStyle = .thin
        delegate = self
        autoresizingMask = [.width, .height]
        for view in views { view.removeFromSuperview(); addSubview(view) }
        arrange(weights)
        setAccessibilityLabel("Website panes")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func arrange(_ weights: [Double]) {
        let length = isVertical ? bounds.width : bounds.height
        let available = max(0, length - dividerThickness * CGFloat(views.count - 1))
        let total = weights.reduce(0, +)
        var position: CGFloat = 0
        for (index, view) in views.enumerated() {
            let size = available * CGFloat(weights[index] / total)
            view.frame = isVertical
                ? NSRect(x: position, y: 0, width: size, height: bounds.height)
                : NSRect(x: 0, y: position, width: bounds.width, height: size)
            position += size + dividerThickness
        }
    }
    override var isFlipped: Bool { true }
    override func resizeSubviews(withOldSize oldSize: NSSize) { arrange(fractions) }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        let view = views[index]
        return (isVertical ? view.frame.minX : view.frame.minY) + minimumPaneLength
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        let view = views[index + 1]
        return (isVertical ? view.frame.maxX : view.frame.maxY) - minimumPaneLength - dividerThickness
    }
    private var minimumPaneLength: CGFloat {
        min(120, max(0, (isVertical ? bounds.width : bounds.height) / CGFloat(views.count) * 0.4))
    }
}
