import AppKit
import SwiftUI
/// Native text storage and selection never enter a website's WebKit process.
@MainActor
public final class SurfaceEditorController: NSObject, ObservableObject, NSTextViewDelegate {
    public weak var textView: NSTextView?
    public var retainedScroll: NSScrollView?
    public let editingUndoManager = UndoManager()
    private var changed: ((String) -> Void)?
    public override init() { super.init() }
    public func undoManager(for view: NSTextView) -> UndoManager? { editingUndoManager }
    public func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        changed?(view.string)
    }
    public var command: (([String: Any]) -> Void)?
    public func bind(_ onChange: @escaping (String) -> Void, command: @escaping ([String: Any]) -> Void) {
        changed = onChange; self.command = command
    }
    func dispose() {
        editingUndoManager.removeAllActions()
        changed = nil
        command = nil
        textView?.delegate = nil
        retainedScroll = nil
        textView = nil
    }

}

/// Each renderer owns a lightweight mount, but the controller owns the editor.
/// Prepared generations cannot move the live editor before authority commits.
@MainActor public final class SurfaceEditorMount: NSView {
    private static let mounts = NSHashTable<SurfaceEditorMount>.weakObjects()
    public var owner = ""
    public var refresh: (() -> Void)?
    public override init(frame: NSRect) { super.init(frame: frame); Self.mounts.add(self) }
    public required init?(coder: NSCoder) { fatalError("init(frame:)") }
    public static func activate(owner: String) {
        for mount in mounts.allObjects where mount.owner == owner { mount.refresh?() }
    }
}
