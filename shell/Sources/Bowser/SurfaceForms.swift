import BowserSurfaceKit
import AppKit
import SwiftUI

/// Keys are scoped to siblings. An explicit key preserves state when rows move.
struct SurfaceNode: Identifiable {
    let id: String
    let value: [String: Any]
    static func children(_ values: [[String: Any]]) -> [SurfaceNode] {
        var counts: [String: Int] = [:]
        return values.enumerated().map { index, value in
            let base = value["key"] as? String ?? "index:\(index)"
            let occurrence = counts[base, default: 0]
            counts[base] = occurrence + 1
            return SurfaceNode(id: "\(base)#\(occurrence)", value: value)
        }
    }
}

struct SurfaceFormView: View {
    @Environment(\.surfaceDispatch) private var dispatch
    var colors = SurfaceColors()
    let surfaceId: String
    let node: [String: Any]
    @StateObject private var model: SurfaceFormModel
    @Environment(\.surfaceEventWebview) private var webview
    @Environment(\.dismiss) private var dismiss
    init(surfaceId: String, node: [String: Any], storeID: String? = nil) {
        self.surfaceId = surfaceId; self.node = node
        _model = StateObject(wrappedValue: SurfaceFormStore.shared.model(surface: storeID ?? surfaceId, key: node["key"] as? String ?? node["event"] as? String ?? "form", initial: node["values"] as? [String: Any] ?? [:], trackedFields: node["tracked_fields"] as? [String]))
    }
    private var fingerprint: Data { (try? JSONSerialization.data(withJSONObject: node, options: .sortedKeys)) ?? Data() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SurfaceTreeView(surfaceId: surfaceId, node: node["content"] as? [String: Any] ?? [:])
                .environment(\.surfaceForm, model)
                .disabled(model.busy)
            if let error = model.errors["_form"] { Text(error).font(.callout).foregroundStyle(colors.color("error")) }
            if node["controls"] as? Bool ?? true { HStack {
                Spacer()
                Button(node["cancel_label"] as? String ?? "Revert") {
                    model.reset()
                    if node["dismiss_on_cancel"] as? Bool == true { dismiss() }
                }
                    .disabled(model.busy || (!model.dirty && node["dismiss_on_cancel"] as? Bool != true))
                Button(model.busy ? "Saving…" : node["submit_label"] as? String ?? "Save Changes") {
                    if let payload = model.begin(required: node["required"] as? [String] ?? [], labels: node["labels"] as? [String: String] ?? [:]) {
                        var message: [String: Any] = ["op": "event", "event": "surface", "surface": surfaceId,
                                                      "id": node["event"] as? String ?? "submit", "value": payload]
                        if let webview { message["webview"] = webview }
                        dispatch(message)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || (node["require_changes"] as? Bool ?? true) && !model.dirty)
            }
        }
        }
        .interactiveDismissDisabled(model.dirty || model.busy)
        .onAppear { model.refresh(node["values"] as? [String: Any] ?? [:], response: node["response"] as? [String: Any]) }
        .onChange(of: fingerprint) { _, _ in
            let response = node["response"] as? [String: Any]
            let succeeded = model.pendingID != nil && response?["request_id"] as? String == model.pendingID && response?["ok"] as? Bool == true
            model.refresh(node["values"] as? [String: Any] ?? [:], response: response)
            if succeeded && node["dismiss_on_success"] as? Bool == true { dismiss() }
        }
    }
}

struct SurfaceInput: View {
    var colors = SurfaceColors()
    let node: [String: Any]
    @Environment(\.surfaceForm) private var form
    var body: some View {
        if let form { SurfaceBoundInput(node: node, model: form) }
        else { Text("Input requires a form").foregroundStyle(colors.color("error")) }
    }
}

private struct SurfaceBoundInput: View {
    var colors = SurfaceColors()
    let node: [String: Any]
    @ObservedObject var model: SurfaceFormModel
    private var field: String { node["field"] as? String ?? "" }
    private var label: String { node["label"] as? String ?? field }
    private var string: Binding<String> {
        Binding(get: { model.values[field] as? String ?? "" }, set: { model.values[field] = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            control
            if let error = model.errors[field] { Text(error).font(.caption).foregroundStyle(colors.color("error")) }
        }.accessibilityLabel(label)
    }
    @ViewBuilder private var control: some View {
        switch node["kind"] as? String ?? "text" {
        case "multiline":
            SurfaceMultilineInput(node: node, text: string)
        case "toggle":
            Toggle(label, isOn: Binding(get: { model.values[field] as? Bool ?? false }, set: { model.values[field] = $0 }))
        case "color":
            ColorPicker(label, selection: Binding(get: {
                Color(nsColor: SurfaceServices.color(hex: model.values[field] as? String) ?? .systemGray)
            }, set: { model.values[field] = SurfaceColorPickerHexBridge.hex(NSColor($0)) }), supportsOpacity: false)
        case "choice":
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: max(1, min(12, node["columns"] as? Int ?? 4))), spacing: 8) {
                ForEach(SurfaceNode.children(node["options"] as? [[String: Any]] ?? [])) { option in
                    let value = option.value["value"] as? String ?? ""
                    let title = option.value["label"] as? String ?? value
                    Button { string.wrappedValue = value } label: {
                        VStack(spacing: 5) {
                            if let path = option.value["path"] as? String, let image = NSImage(contentsOfFile: path) {
                                Image(nsImage: image).resizable().scaledToFit().frame(width: 40, height: 40)
                            } else if let symbol = option.value["symbol"] as? String {
                                Image(systemName: symbol).font(.system(size: 28)).frame(height: 40)
                            }
                            Text(title).font(.caption).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity).padding(8)
                        .background(string.wrappedValue == value ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(string.wrappedValue == value ? Color.accentColor : .clear, lineWidth: 2))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(title)
                        .accessibilityValue(string.wrappedValue == value ? "Selected" : "Not selected")
                }
            }
        default:
            TextField(node["placeholder"] as? String ?? label, text: string).textFieldStyle(.roundedBorder)
        }
    }
}

struct SurfacePresentation: View {
    var colors = SurfaceColors()
    let surfaceId: String
    let node: [String: Any]
    @State private var presented = false
    @Environment(\.surfaceForm) private var form
    var body: some View {
        Button(node["label"] as? String ?? "Open") { presented = true }
            .sheet(isPresented: Binding(get: { presented && node["t"] as? String == "sheet" }, set: { presented = $0 })) {
                content
            }
            .popover(isPresented: Binding(get: { presented && node["t"] as? String == "popover" }, set: { presented = $0 })) {
                content
            }
    }
    private var content: some View {
        SurfaceTreeView(surfaceId: surfaceId, node: node["content"] as? [String: Any] ?? [:])
            .onAppear { SurfaceServices.shared.presentations += 1 }
            .onDisappear { SurfaceServices.shared.presentations = max(0, SurfaceServices.shared.presentations - 1) }
            .environment(\.surfaceForm, form)
            .environment(\.surfacePalette, colors.palette)
            .foregroundStyle(colors.color("text"))
            .padding(24)
            .background(colors.color("surface"))
            .frame(width: max(240, min(1000, (node["content_width"] as? Double).map { CGFloat($0) } ?? 480)))
    }
}

struct SurfaceNativeAction: View {
    let node: [String: Any]
    let emit: (String, Any?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.surfaceForm) private var form
    var body: some View {
        styled
            .disabled(node["disabled"] as? Bool ?? false)
            .modifier(SurfaceShortcut(value: node["shortcut"] as? String))
    }
    private var button: some View {
        Button(role: node["role"] as? String == "destructive" ? .destructive : nil) {
            if let command = node["command"] as? [String: Any], let form {
                if let payload = form.perform(command) { emit(node["event"] as? String ?? "click", payload) }
            } else if node["action"] as? String == "dismiss" {
                if form?.confirmDiscard() ?? true { dismiss() }
            } else { emit(node["event"] as? String ?? "click", node["payload"]) }
        } label: {
            if let symbol = node["symbol"] as? String {
                if node["label_style"] as? String == "icon" { Image(systemName: symbol).accessibilityLabel(node["label"] as? String ?? "") }
                else { Label(node["label"] as? String ?? "", systemImage: symbol) }
            }
            else { Text(node["label"] as? String ?? "") }
        }
    }
    @ViewBuilder private var styled: some View {
        if node["button_style"] as? String == "plain" { button.buttonStyle(.plain) }
        else if node["button_style"] as? String == "borderless" { button.buttonStyle(.borderless) }
        else if node["role"] as? String == "primary" { button.buttonStyle(.borderedProminent) }
        else { button.buttonStyle(.bordered) }
    }
}
private struct SurfaceShortcut: ViewModifier {
    let value: String?
    @ViewBuilder func body(content: Content) -> some View {
        switch value {
        case "default": content.keyboardShortcut(.defaultAction)
        case "cancel": content.keyboardShortcut(.cancelAction)
        case .some(let key) where key.count == 1: content.keyboardShortcut(KeyEquivalent(Character(key)), modifiers: .command)
        default: content
        }
    }
}

struct SurfaceListDetail: View {
    let surfaceId: String
    let node: [String: Any]
    @StateObject private var selectionModel: SurfaceFormModel
    init(surfaceId: String, node: [String: Any]) {
        self.surfaceId = surfaceId; self.node = node
        _selectionModel = StateObject(wrappedValue: SurfaceFormStore.shared.model(surface: surfaceId,
            key: "selection:" + (node["key"] as? String ?? "list_detail"), initial: [:]))
    }
    private var selection: String? {
        get { selectionModel.values["selection"] as? String }
        nonmutating set { selectionModel.values["selection"] = newValue }
    }
    private var items: [[String: Any]] { node["items"] as? [[String: Any]] ?? [] }
    private var selected: String? {
        let candidate = selection ?? node["selection"] as? String
        return items.contains { $0["id"] as? String == candidate } ? candidate : items.first?["id"] as? String
    }
    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { selected }, set: { selection = $0 })) {
                ForEach(SurfaceNode.children(items.map { item in var copy = item; copy["key"] = item["id"]; return copy })) { item in
                    Label(item.value["title"] as? String ?? "", systemImage: item.value["symbol"] as? String ?? "circle")
                        .tag(item.value["id"] as? String ?? "")
                }
            }.frame(width: node["sidebar_width"] as? Double ?? 180)
            Divider()
            if let item = items.first(where: { $0["id"] as? String == selected }) {
                SurfaceTreeView(surfaceId: surfaceId, node: item["detail"] as? [String: Any] ?? [:])
                    .id(selected).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.frame(minHeight: (node["min_height"] as? Double).map { CGFloat($0) } ?? 320)
    }
}

struct SurfaceNodeStyle: ViewModifier {
    var colors = SurfaceColors()
    let node: [String: Any]
    static func horizontal(_ value: String?) -> HorizontalAlignment {
        switch value { case "center": return .center; case "trailing": return .trailing; default: return .leading }
    }
    func body(content: Content) -> some View {
        content
            .frame(width: (node["width"] as? Double).map { CGFloat($0) }, height: (node["height"] as? Double).map { CGFloat($0) })
            .frame(minWidth: (node["min_width"] as? Double).map { CGFloat($0) },
                   maxWidth: node["fill_width"] as? Bool == true ? .infinity : (node["max_width"] as? Double).map { CGFloat($0) },
                   minHeight: (node["min_height"] as? Double).map { CGFloat($0) },
                   maxHeight: node["fill_height"] as? Bool == true ? .infinity : (node["max_height"] as? Double).map { CGFloat($0) },
                   alignment: .leading)
            .padding(node["padding"] as? Double ?? 0)
            .background(node["background"].map { colors.color($0, fallback: "surface") } ?? .clear)
            .clipShape(RoundedRectangle(cornerRadius: node["corner_radius"] as? Double ?? 0))
            .overlay(RoundedRectangle(cornerRadius: node["corner_radius"] as? Double ?? 0)
                .strokeBorder(node["border"].map { colors.color($0, fallback: "separator") } ?? .clear, lineWidth: 1))
            .modifier(SurfaceFontSize(size: node["font_size"] as? Double))
            .modifier(SurfaceForeground(color: node["foreground"]))
            .controlSize(node["control_size"] as? String == "small" ? .small : node["control_size"] as? String == "mini" ? .mini : .regular)
            .modifier(SurfaceAccessibility(node: node))
    }
}
private struct SurfaceAccessibility: ViewModifier {
    let node: [String: Any]
    @ViewBuilder func body(content: Content) -> some View {
        if let label = node["accessibility_label"] as? String {
            content.accessibilityLabel(label).help(node["help"] as? String ?? "")
        } else { content.help(node["help"] as? String ?? "") }
    }
}

private struct SurfaceForeground: ViewModifier {
    var colors = SurfaceColors()
    let color: Any?
    @ViewBuilder func body(content: Content) -> some View {
        if let color { content.foregroundStyle(colors.color(color)) }
        else { content }
    }
}

private struct SurfaceFontSize: ViewModifier {
    let size: Double?
    @ViewBuilder func body(content: Content) -> some View {
        if let size { content.font(.system(size: max(8, min(72, size)))) }
        else { content }
    }
}
