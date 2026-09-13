import AppKit
import SwiftUI
import BowserSurfaceKit

struct SurfaceNativeTextEditor: NSViewRepresentable {
    var colors = SurfaceColors()
    @Binding var text: String
    let controller: SurfaceEditorController
    let monospaced: Bool
    let editable: Bool
    let label: String
    var fontSize: Double = 14
    var foreground: Any? = nil
    var background: Any? = nil

    init(text: Binding<String>, controller: SurfaceEditorController, monospaced: Bool, editable: Bool, label: String, fontSize: Double = 14, foreground: Any? = nil, background: Any? = nil) {
        self._text = text; self.controller = controller; self.monospaced = monospaced
        self.editable = editable; self.label = label; self.fontSize = fontSize
        self.foreground = foreground; self.background = background
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @Environment(\.surfaceRenderOwner) private var owner
    @Environment(\.surfaceRenderGeneration) private var generation
    func makeNSView(context: Context) -> SurfaceEditorMount {
        let mount = SurfaceEditorMount()
        mount.owner = owner
        updateNSView(mount, context: context)
        return mount
    }
    func updateNSView(_ mount: SurfaceEditorMount, context: Context) {
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
            view.string = text
            controller.retainedScroll = scroll
        }
        guard let view = scroll.documentView as? NSTextView else { return }
        if scroll.superview !== mount {
            scroll.removeFromSuperview()
            scroll.frame = mount.bounds; scroll.autoresizingMask = [.width, .height]
            mount.addSubview(scroll)
        }
        controller.bind({ [weak coordinator] value in coordinator?.parent.text = value },
            command: { [weak controller, owner, generation] command in
                guard owner.isEmpty || SurfaceRenderContext.contexts[owner]?.generation == generation else { return }
                controller?.applyEditorCommand(command)
            })
        view.delegate = controller
        controller.textView = view
        configure(view, scroll: scroll)
        if view.string != text && !view.hasMarkedText() {
            let selection = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            view.undoManager?.removeAllActions()
        }
    }
    private func configure(_ view: NSTextView, scroll: NSScrollView) {
        view.isRichText = false; view.importsGraphics = false; view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.autoresizingMask = [.width]
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.hasHorizontalScroller = false; scroll.borderType = .noBorder

        view.isEditable = editable
        let size = max(8, min(72, fontSize))
        view.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
        view.textColor = colors.native(foreground, fallback: "text")
        view.backgroundColor = colors.native(background, fallback: "editor_background")
        view.insertionPointColor = colors.native(foreground, fallback: "text")
        view.selectedTextAttributes = [.backgroundColor: colors.native("selection"), .foregroundColor: colors.native("selected_text")]
        view.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SurfaceNativeTextEditor
        init(_ parent: SurfaceNativeTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}



/// Behavior is rebound by the active component; storage and undo stay in the SDK.
extension SurfaceEditorController {
    func insert(prefix: String, suffix: String) {
        guard let view = textView, view.isEditable else { return }
        let range = view.selectedRange()
        let selected = (view.string as NSString).substring(with: range)
        view.insertText(prefix + selected + suffix, replacementRange: range)
        view.setSelectedRange(NSRange(location: range.location + (prefix as NSString).length, length: (selected as NSString).length))
        view.window?.makeFirstResponder(view)
    }
    func applyEditorCommand(_ command: [String: Any]) {
        guard let view = textView, view.isEditable else { return }
        switch command["op"] as? String {
        case "wrap": insert(prefix: command["prefix"] as? String ?? "", suffix: command["suffix"] as? String ?? "")
        case "insert": view.insertText(command["text"] as? String ?? "", replacementRange: view.selectedRange())
        case "select":
            let length = (view.string as NSString).length
            let start = max(0, min(length, command["location"] as? Int ?? 0))
            let count = max(0, min(length - start, command["length"] as? Int ?? 0))
            view.setSelectedRange(NSRange(location: start, length: count))
        case "undo": if view.undoManager?.canUndo == true { view.undoManager?.undo(); view.didChangeText() }
        case "redo": if view.undoManager?.canRedo == true { view.undoManager?.redo(); view.didChangeText() }
        default: return
        }
        view.window?.makeFirstResponder(view)
    }
}
