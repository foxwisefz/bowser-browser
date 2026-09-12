import AppKit

/// Declarative layout. Structural limits bound validation/rendering work, not
/// the number of panes in a row or the arrangements mods may compose.
struct WebsiteLayoutNode {
    let type: String
    let webview: UInt64?
    let children: [WebsiteLayoutNode]
    var weight: Double
    let minWidth: CGFloat
    let minHeight: CGFloat
    let resizable: Bool

    var ids: [UInt64] { webview.map { [$0] } ?? children.flatMap(\.ids) }
    var minimumSize: NSSize {
        let sizes = children.map(\.minimumSize)
        let dividers = CGFloat(max(0, children.count - 1))
        let width = type == "row" ? sizes.reduce(0) { $0 + $1.width } + dividers : sizes.map(\.width).max() ?? 0
        let height = type == "column" ? sizes.reduce(0) { $0 + $1.height } + dividers : sizes.map(\.height).max() ?? 0
        return NSSize(width: max(minWidth, width), height: max(minHeight, height))
    }
    var json: [String: Any] {
        var result: [String: Any] = ["type": type, "weight": weight, "min_width": minWidth, "min_height": minHeight]
        if let webview { result["webview"] = webview }
        else { result["children"] = children.map(\.json); result["resizable"] = resizable }
        return result
    }

    func removing(_ id: UInt64) -> Self? {
        if let webview { return webview == id ? nil : self }
        let remaining = children.compactMap { $0.removing(id) }
        guard !remaining.isEmpty else { return nil }
        if remaining.count == 1 {
            let child = remaining[0]
            return Self(type: child.type, webview: child.webview, children: child.children,
                        weight: weight, minWidth: max(minWidth, child.minWidth),
                        minHeight: max(minHeight, child.minHeight), resizable: child.resizable)
        }
        return Self(type: type, webview: nil, children: remaining, weight: weight,
                    minWidth: minWidth, minHeight: minHeight, resizable: resizable)
    }

    static func parse(_ raw: [String: Any]) throws -> Self {
        var count = 0
        let node = try parse(raw, depth: 0, count: &count)
        guard Set(node.ids).count == node.ids.count else { throw error("Each website view may appear only once") }
        return node
    }
    private static func parse(_ raw: [String: Any], depth: Int, count: inout Int) throws -> Self {
        count += 1
        guard depth < 16, count <= 256 else { throw error("Layout exceeds 16 levels or 256 nodes") }
        guard let type = raw["type"] as? String, ["row", "column", "webview"].contains(type) else { throw error("Expected row, column or webview node") }
        func number(_ key: String, fallback: Double) throws -> Double {
            guard let value = raw[key] else { return fallback }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw error("\(key) must be a finite number") }
            return number.doubleValue
        }
        let weight = try number("weight", fallback: 1)
        let minWidth = try number("min_width", fallback: 0), minHeight = try number("min_height", fallback: 0)
        guard weight > 0, minWidth >= 0, minHeight >= 0 else { throw error("Weights must be positive and minimum sizes nonnegative") }
        let children: [Self]
        let webview: UInt64?
        var resizable = true
        if type == "webview" {
            guard let id = raw["webview"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(),
                  id.doubleValue > 0, id.doubleValue < Double(UInt64.max), id.doubleValue.rounded() == id.doubleValue,
                  raw["children"] == nil else { throw error("A webview leaf requires a positive tab ID and no children") }
            webview = id.uint64Value
            children = []
        } else {
            guard let list = raw["children"] as? [[String: Any]], !list.isEmpty, raw["webview"] == nil else { throw error("Containers require nonempty children and no webview ID") }
            if let value = raw["resizable"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw error("resizable must be a boolean") }
                resizable = number.boolValue
            }
            children = try list.map { try parse($0, depth: depth + 1, count: &count) }
            webview = nil
        }
        let node = Self(type: type, webview: webview, children: children, weight: weight,
                        minWidth: minWidth, minHeight: minHeight, resizable: resizable)
        guard node.minimumSize.width.isFinite, node.minimumSize.height.isFinite else { throw error("Combined minimum sizes overflow") }
        return node
    }
    private static func error(_ text: String) -> NSError {
        NSError(domain: "Bowser.WebsiteLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

@MainActor
final class WebsiteLayout: NSView {
    let node: WebsiteLayoutNode
    let views: [EngineView]
    let content: NSView
    var ids: [UInt64] { views.map(\.webviewId) }
    var tree: [String: Any] { (content as? WebsiteSplit)?.snapshot ?? node.json }

    init(frame: NSRect, node: WebsiteLayoutNode, views: [UInt64: EngineView]) {
        self.node = node
        self.views = node.ids.map { views[$0]! }
        content = Self.build(node, frame: NSRect(origin: .zero, size: frame.size), views: views)
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        setAccessibilityLabel("Website layout")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private static func build(_ node: WebsiteLayoutNode, frame: NSRect, views: [UInt64: EngineView]) -> NSView {
        if let id = node.webview {
            let view = views[id]!
            view.removeFromSuperview()
            view.frame = frame
            return view
        }
        let children = node.children.map { build($0, frame: frame, views: views) }
        return WebsiteSplit(frame: frame, node: node, children: children)
    }
}

@MainActor
final class WebsiteSplit: NSSplitView, NSSplitViewDelegate {
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
            var child = (pair.1 as? WebsiteSplit)?.snapshot ?? pair.0.json
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
