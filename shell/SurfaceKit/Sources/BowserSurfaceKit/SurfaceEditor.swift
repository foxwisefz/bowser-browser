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
    fileprivate func bind(_ onChange: @escaping (String) -> Void) { changed = onChange }
    func dispose() {
        editingUndoManager.removeAllActions()
        changed = nil
        textView?.delegate = nil
        retainedScroll = nil
        textView = nil
    }
    public func insert(prefix: String, suffix: String) {
        guard let view = textView, view.isEditable else { return }
        let range = view.selectedRange()
        let selected = (view.string as NSString).substring(with: range)
        view.insertText(prefix + selected + suffix, replacementRange: range)
        view.setSelectedRange(NSRange(location: range.location + (prefix as NSString).length, length: (selected as NSString).length))
        view.window?.makeFirstResponder(view)
    }
}

public struct SurfaceNativeTextEditor: NSViewRepresentable {
    public var colors = SurfaceColors()
    @Binding public var text: String
    public let controller: SurfaceEditorController
    public let monospaced: Bool
    public let editable: Bool
    public let label: String
    public var fontSize: Double = 14
    public var foreground: Any? = nil
    public var background: Any? = nil

    public init(text: Binding<String>, controller: SurfaceEditorController, monospaced: Bool, editable: Bool, label: String, fontSize: Double = 14, foreground: Any? = nil, background: Any? = nil) {
        self._text = text; self.controller = controller; self.monospaced = monospaced
        self.editable = editable; self.label = label; self.fontSize = fontSize
        self.foreground = foreground; self.background = background
    }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    @Environment(\.surfaceRenderOwner) private var owner
    @Environment(\.surfaceRenderGeneration) private var generation
    public func makeNSView(context: Context) -> SurfaceEditorMount {
        let mount = SurfaceEditorMount()
        mount.owner = owner
        updateNSView(mount, context: context)
        return mount
    }
    public func updateNSView(_ mount: SurfaceEditorMount, context: Context) {
        context.coordinator.parent = self
        let coordinator = context.coordinator
        mount.refresh = { [weak mount, weak coordinator] in
            guard let mount, let coordinator else { return }
            coordinator.parent.attach(to: mount, coordinator: coordinator)
        }
        mount.refresh?()
    }
    private func attach(to mount: SurfaceEditorMount, coordinator: Coordinator) {
        guard owner.isEmpty || SurfaceRenderContext.contexts[owner]?.generation == generation else { return }
        let scroll: NSScrollView
        if let existing = controller.retainedScroll { scroll = existing }
        else {
            scroll = NSTextView.scrollableTextView()
            let view = scroll.documentView as! NSTextView
            view.isRichText = false; view.importsGraphics = false; view.allowsUndo = true
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.textContainerInset = NSSize(width: 12, height: 12)
            view.autoresizingMask = [.width]
            view.isHorizontallyResizable = false; view.isVerticallyResizable = true
            view.textContainer?.widthTracksTextView = true
            view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            view.string = text
            scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay; scroll.hasHorizontalScroller = false; scroll.borderType = .noBorder
            controller.retainedScroll = scroll
        }
        guard let view = scroll.documentView as? NSTextView else { return }
        if scroll.superview !== mount {
            scroll.removeFromSuperview()
            scroll.frame = mount.bounds; scroll.autoresizingMask = [.width, .height]
            mount.addSubview(scroll)
        }
        controller.bind { [weak coordinator] value in coordinator?.parent.text = value }
        view.delegate = controller
        controller.textView = view
        configure(view)
        if view.string != text && !view.hasMarkedText() {
            let selection = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            view.undoManager?.removeAllActions()
        }
    }
    private func configure(_ view: NSTextView) {
        view.isEditable = editable
        let size = max(8, min(72, fontSize))
        view.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
        view.textColor = colors.native(foreground, fallback: "text")
        view.backgroundColor = colors.native(background, fallback: "editor_background")
        view.insertionPointColor = colors.native(foreground, fallback: "text")
        view.selectedTextAttributes = [.backgroundColor: colors.native("selection"), .foregroundColor: colors.native("selected_text")]
        view.setAccessibilityLabel(label)
    }
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SurfaceNativeTextEditor
        init(_ parent: SurfaceNativeTextEditor) { self.parent = parent }
        public func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}


/// Each renderer owns a lightweight mount, but the controller owns the editor.
/// Prepared generations cannot move the live editor before authority commits.
@MainActor public final class SurfaceEditorMount: NSView {
    private static let mounts = NSHashTable<SurfaceEditorMount>.weakObjects()
    var owner = ""
    var refresh: (() -> Void)?
    public override init(frame: NSRect) { super.init(frame: frame); Self.mounts.add(self) }
    public required init?(coder: NSCoder) { fatalError("init(frame:)") }
    public static func activate(owner: String) {
        for mount in mounts.allObjects where mount.owner == owner { mount.refresh?() }
    }
}
