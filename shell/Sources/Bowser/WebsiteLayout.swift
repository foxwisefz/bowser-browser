import AppKit
import BowserSurfaceKit

/// Stable owner of the website views; only their layout containers are replaced.
@MainActor final class WebsiteLayout: NSView {
    private static let live = NSHashTable<WebsiteLayout>.weakObjects()
    let node: WebsiteLayoutNode
    let views: [EngineView]
    private(set) var content: NSView
    var ids: [UInt64] { views.map(\.webviewId) }
    var tree: [String: Any] { (content as? any WebsiteSplitSnapshot)?.snapshot ?? node.json }
    init(frame: NSRect, node: WebsiteLayoutNode, views: [UInt64: EngineView]) {
        self.node = node; self.views = node.ids.map { views[$0]! }
        let build = NativeUIHost.shared.state.layout ?? WebsiteSplitRenderer.build
        content = build(node, NSRect(origin: .zero, size: frame.size), views.mapValues { $0 as NSView })
        super.init(frame: frame)
        autoresizingMask = [.width, .height]; content.autoresizingMask = [.width, .height]
        addSubview(content); setAccessibilityLabel("Website layout")
        Self.live.add(self)
        NativeUIHost.shared.state.layoutChanged = { Self.refreshAll() }
    }
    required init?(coder: NSCoder) { fatalError("init(frame:node:views:)") }
    static func refreshAll() {
        for layout in live.allObjects where layout.superview != nil { layout.replaceContainers() }
    }
    func replaceContainers() {
        guard let current = try? WebsiteLayoutNode.parse(tree) else { return }
        let responder = window?.firstResponder
        let old = content
        let build = NativeUIHost.shared.state.layout ?? WebsiteSplitRenderer.build
        content = build(current, bounds, Dictionary(uniqueKeysWithValues: views.map { ($0.webviewId, $0 as NSView) }))
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        if old !== content { old.removeFromSuperview() }
        if let view = responder as? NSView, view.isDescendant(of: self) { window?.makeFirstResponder(view) }
    }
}
