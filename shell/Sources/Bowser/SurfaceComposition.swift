import AppKit
import SwiftUI

private struct SurfaceStateNamespaceKey: EnvironmentKey { static let defaultValue = "" }
private struct SurfaceEventWebviewKey: EnvironmentKey { static let defaultValue: UInt64? = nil }
extension EnvironmentValues {
    var surfaceStateNamespace: String {
        get { self[SurfaceStateNamespaceKey.self] }
        set { self[SurfaceStateNamespaceKey.self] = newValue }
    }
    var surfaceEventWebview: UInt64? {
        get { self[SurfaceEventWebviewKey.self] }
        set { self[SurfaceEventWebviewKey.self] = newValue }
    }
}

/// Commands target only the nearest local model, never a global editor ID.
extension SurfaceFormModel {
    @discardableResult
    func perform(_ command: [String: Any]) -> [String: Any]? {
        guard !busy, let op = command["op"] as? String else { return nil }
        let field = command["field"] as? String ?? ""
        switch op {
        case "set":
            if !field.isEmpty, let value = command["value"] { values[field] = value }
        case "toggle":
            if !field.isEmpty { values[field] = !(values[field] as? Bool ?? false) }
        case "reset": reset()
        case "discard": return confirmDiscard() ? [:] : nil
        case "submit": return begin(required: command["required"] as? [String] ?? [], labels: command["labels"] as? [String: String] ?? [:])
        case "snapshot":
            let fields = command["fields"] as? [String] ?? []
            var selections: [String: Any] = [:]
            for key in fields {
                if let view = editor(key).textView {
                    let range = view.selectedRange()
                    selections[key] = ["location": range.location, "length": range.length]
                }
            }
            return ["values": values.filter { fields.contains($0.key) }, "selections": selections]
        case "wrap": editor(field).insert(prefix: command["prefix"] as? String ?? "", suffix: command["suffix"] as? String ?? "")
        case "insert", "select", "undo", "redo":
            guard let view = editor(field).textView, view.isEditable else { return nil }
            switch op {
            case "insert": view.insertText(command["text"] as? String ?? "", replacementRange: view.selectedRange())
            case "select":
                let length = (view.string as NSString).length
                let start = max(0, min(length, command["location"] as? Int ?? 0))
                let count = max(0, min(length - start, command["length"] as? Int ?? 0))
                view.setSelectedRange(NSRange(location: start, length: count))
            case "undo": if view.undoManager?.canUndo == true { view.undoManager?.undo() }
            default: if view.undoManager?.canRedo == true { view.undoManager?.redo() }
            }
            view.window?.makeFirstResponder(view)
        default: break
        }
        return nil
    }
}

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
    let surfaceId: String
    let node: [String: Any]
    @Environment(\.surfaceForm) private var model
    var body: some View {
        if let model { SurfaceBoundContent(surfaceId: surfaceId, node: node, model: model) }
        else { Text("This control requires a state or form scope").foregroundStyle(.red) }
    }
}

private struct SurfaceBoundContent: View {
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
                if let error = model.errors[field] { Text(error).foregroundStyle(.red).font(.caption) }
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
