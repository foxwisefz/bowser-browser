import BowserSurfaceKit
import AppKit
import SwiftUI
struct SurfaceModelScope: View {
    let surfaceId: String
    let node: [String: Any]
    @Environment(\.surfaceStateNamespace) private var namespace
    var body: some View {
        SurfaceFormView(surfaceId: surfaceId, node: definition, storeID: namespace.isEmpty ? surfaceId : namespace + "|" + surfaceId)
            .id(namespace + "|" + surfaceId + "|" + (node["key"] as? String ?? "form"))
    }
    private var definition: [String: Any] {
        guard node["t"] as? String == "state" else { return node }
        var copy = node
        copy["controls"] = false
        return copy
    }
}

struct SurfaceBoundView: View {
    var colors = SurfaceColors()
    let surfaceId: String
    let node: [String: Any]
    @Environment(\.surfaceForm) private var model
    var body: some View {
        if let model { SurfaceBoundContent(surfaceId: surfaceId, node: node, model: model) }
        else { Text("This control requires a state or form scope").foregroundStyle(colors.color("error")) }
    }
}

private struct SurfaceBoundContent: View {
    var colors = SurfaceColors()
    let surfaceId: String
    let node: [String: Any]
    @ObservedObject var model: SurfaceFormModel
    private var field: String { node["field"] as? String ?? "" }
    private var string: Binding<String> {
        Binding(get: { model.values[field] as? String ?? "" }, set: { model.values[field] = $0 })
    }
    @ViewBuilder var body: some View {
        switch node["t"] as? String {
        case "editor":
            VStack(alignment: .leading, spacing: 4) {
                SurfaceMultilineInput(node: node, text: string)
                if let error = model.errors[field] { Text(error).foregroundStyle(colors.color("error")).font(.caption) }
            }
        case "preview": SurfaceMarkdownPreview(text: string.wrappedValue)
        case "selector":
            if node["style"] as? String == "menu" { selector.pickerStyle(.menu) }
            else { selector.pickerStyle(.segmented) }
        case "switch":
            // Retain mounted views (and editor undo/selection) across mode changes.
            let cases = node["cases"] as? [[String: Any]] ?? []
            ZStack(alignment: .topLeading) {
                ForEach(SurfaceNode.children(cases)) { branch in
                    let active = branch.value["value"] as? String == string.wrappedValue
                    SurfaceTreeView(surfaceId: surfaceId, node: branch.value["content"] as? [String: Any] ?? [:])
                        .opacity(active ? 1 : 0).allowsHitTesting(active).accessibilityHidden(!active)
                        .disabled(!active)
                }
            }
        default: EmptyView()
        }
    }
    private var selector: some View {
        Picker(node["label"] as? String ?? field, selection: string) {
            ForEach(SurfaceNode.children(node["options"] as? [[String: Any]] ?? [])) { option in
                Text(option.value["label"] as? String ?? "").tag(option.value["value"] as? String ?? "")
            }
        }.labelsHidden().accessibilityLabel(node["label"] as? String ?? field)
    }
}

/// Wrapping is a layout behavior reusable for any child views, not an editor feature.
struct SurfaceFlowLayout: Layout {
    var spacing: CGFloat = 6
    static func frames(sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [CGRect] {
        let width = max(0, width)
        let spacing = max(0, spacing)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        return sizes.map { size in
            let size = CGSize(width: min(max(0, size.width), width), height: max(0, size.height))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            return frame
        }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? sizes.reduce(0) { $0 + $1.width + spacing }
        let frames = Self.frames(sizes: sizes, width: width, spacing: spacing)
        return CGSize(width: max(0, width), height: frames.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = Self.frames(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, width: bounds.width, spacing: spacing)
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}
