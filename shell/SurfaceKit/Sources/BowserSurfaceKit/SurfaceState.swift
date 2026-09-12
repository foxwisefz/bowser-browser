import AppKit
import SwiftUI
/// Local form state survives tree refreshes; only a matching reply ends a submission.
@MainActor
public final class SurfaceFormModel: ObservableObject {
    @Published public var values: [String: Any]
    @Published public private(set) var errors: [String: String] = [:]
    @Published public private(set) var pendingID: String?
    private var baseline: [String: Any]
    private var submitted: [String: Any] = [:]
    private var editors: [String: SurfaceEditorController] = [:]
    public func editor(_ field: String) -> SurfaceEditorController {
        if let existing = editors[field] { return existing }
        let controller = SurfaceEditorController()
        editors[field] = controller
        return controller
    }
    func disposeEditors() { editors.values.forEach { $0.dispose() }; editors.removeAll() }
    private let trackedFields: Set<String>?
    public init(_ values: [String: Any], trackedFields: [String]? = nil) {
        self.values = values; baseline = values; self.trackedFields = trackedFields.map(Set.init)
    }
    private func tracked(_ map: [String: Any]) -> [String: Any] {
        guard let trackedFields else { return map }
        return map.filter { trackedFields.contains($0.key) }
    }
    public var dirty: Bool { !NSDictionary(dictionary: tracked(values)).isEqual(to: tracked(baseline)) }
    public var busy: Bool { pendingID != nil }

    public func refresh(_ initial: [String: Any], response: [String: Any]?) {
        if let response, let pendingID, response["request_id"] as? String == pendingID {
            self.pendingID = nil
            if response["ok"] as? Bool == true {
                values = response["values"] as? [String: Any] ?? submitted
                baseline = values
                errors = [:]
            } else {
                errors = response["errors"] as? [String: String] ?? [:]
                errors["_form"] = response["error"] as? String ?? "Could not save. Check your changes and try again."
            }
        } else if !dirty && !busy {
            // Keep untracked UI choices when the mod re-sends the same defaults.
            for (key, value) in initial {
                if !NSDictionary(dictionary: [key: value]).isEqual(to: baseline[key].map { [key: $0] } ?? [:]) {
                    values[key] = value
                }
            }
            for key in baseline.keys where initial[key] == nil { values.removeValue(forKey: key) }
            baseline = initial
        }
    }

    public func begin(required: [String], labels: [String: String] = [:]) -> [String: Any]? {
        guard !busy else { return nil }
        errors = [:]
        for key in required where (values[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors[key] = "Enter \(labels[key] ?? key)."
        }
        guard errors.isEmpty else { return nil }
        let id = UUID().uuidString
        pendingID = id
        submitted = values
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.expire(id) }
        return ["request_id": id, "values": submitted]
    }
    public func expire(_ id: String) {
        guard pendingID == id else { return }
        pendingID = nil
        errors["_form"] = "No response received. Your changes are still here; try again."
    }
    public func reset() { guard !busy else { return }; values = baseline; errors = [:] }
    public func confirmDiscard() -> Bool {
        guard !busy else { return false }
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Your changes have not been saved."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Changes")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        reset()
        return true
    }
}

private struct SurfaceFormKey: EnvironmentKey {
    public static let defaultValue: SurfaceFormModel? = nil
}
extension EnvironmentValues {
    public var surfaceForm: SurfaceFormModel? {
        get { self[SurfaceFormKey.self] }
        set { self[SurfaceFormKey.self] = newValue }
    }
}

/// Form keys are unique within a surface, so changing categories or selected
/// detail rows doesn't throw away local edits. Closing a surface releases them.
@MainActor
public final class SurfaceFormStore {
    public init() {}
    public static let shared = SurfaceFormStore()
    private var surfaces: [String: [String: SurfaceFormModel]] = [:]
    public func model(surface: String, key: String, initial: [String: Any], trackedFields: [String]? = nil) -> SurfaceFormModel {
        if let existing = surfaces[surface]?[key] { return existing }
        let model = SurfaceFormModel(initial, trackedFields: trackedFields)
        surfaces[surface, default: [:]][key] = model
        return model
    }
    public func remove(surface: String) {
        surfaces.removeValue(forKey: surface)?.values.forEach { $0.disposeEditors() }
    }
}

private struct SurfaceStateNamespaceKey: EnvironmentKey { static let defaultValue = "" }
private struct SurfaceEventWebviewKey: EnvironmentKey { static let defaultValue: UInt64? = nil }
extension EnvironmentValues {
    public var surfaceStateNamespace: String {
        get { self[SurfaceStateNamespaceKey.self] }
        set { self[SurfaceStateNamespaceKey.self] = newValue }
    }
    public var surfaceEventWebview: UInt64? {
        get { self[SurfaceEventWebviewKey.self] }
        set { self[SurfaceEventWebviewKey.self] = newValue }
    }
}

/// Commands target only the nearest local model, never a global editor ID.
extension SurfaceFormModel {
    @discardableResult
    public func perform(_ command: [String: Any]) -> [String: Any]? {
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
            case "undo": if view.undoManager?.canUndo == true { view.undoManager?.undo(); view.didChangeText() }
            default: if view.undoManager?.canRedo == true { view.undoManager?.redo(); view.didChangeText() }
            }
            view.window?.makeFirstResponder(view)
        default: break
        }
        return nil
    }
}

