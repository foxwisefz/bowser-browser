import AppKit
import SwiftUI

/// Native text storage and selection never enter a website's WebKit process.
@MainActor
final class SurfaceEditorController: ObservableObject {
    weak var textView: NSTextView?
    func insert(prefix: String, suffix: String) {
        guard let view = textView, view.isEditable else { return }
        let range = view.selectedRange()
        let selected = (view.string as NSString).substring(with: range)
        view.insertText(prefix + selected + suffix, replacementRange: range)
        view.setSelectedRange(NSRange(location: range.location + (prefix as NSString).length, length: (selected as NSString).length))
        view.window?.makeFirstResponder(view)
    }
}

struct SurfaceNativeTextEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: SurfaceEditorController
    let monospaced: Bool
    let editable: Bool
    let label: String
    var fontSize: Double = 14
    var foreground: String? = nil
    var background: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.autoresizingMask = [.width]
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        view.delegate = context.coordinator
        view.string = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        controller.textView = view
        configure(view)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        controller.textView = view
        configure(view)
        // Unrelated surface refreshes must preserve selection, composition and undo.
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
        view.textColor = Profile.color(hex: foreground) ?? .textColor
        view.backgroundColor = Profile.color(hex: background) ?? .textBackgroundColor
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

/// An editor is only an editing surface. Its model owns selection and commands;
/// sibling views decide how to present tools and previews.
struct SurfaceMultilineInput: View {
    let node: [String: Any]
    @Binding var text: String
    @Environment(\.isEnabled) private var enabled
    @Environment(\.surfaceForm) private var model
    @StateObject private var fallback = SurfaceEditorController()
    var body: some View {
        ZStack(alignment: .topLeading) {
            SurfaceNativeTextEditor(text: $text,
                controller: model?.editor(node["field"] as? String ?? "") ?? fallback,
                monospaced: node["monospaced"] as? Bool ?? false, editable: enabled,
                label: node["label"] as? String ?? "Text editor", fontSize: node["font_size"] as? Double ?? 14,
                foreground: node["foreground"] as? String, background: node["background"] as? String)
            if text.isEmpty {
                Text(node["placeholder"] as? String ?? "")
                    .foregroundStyle(.secondary).padding(16).allowsHitTesting(false)
            }
        }.frame(minHeight: 100, maxHeight: .infinity)
    }
}

/// Text-only Markdown preview: no HTML execution, web views or image fetches.
struct SurfaceMarkdownPreview: View {
    let text: String
    struct Line {
        let text: String
        let heading: Int
        let code: Bool
        let quote: Bool
    }
    static func lines(_ text: String) -> [Line] {
        var code = false
        return text.components(separatedBy: "\n").compactMap { source in
            if source.hasPrefix("```") { code.toggle(); return nil }
            if code { return Line(text: source, heading: 0, code: true, quote: false) }
            let hashes = source.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), source.dropFirst(hashes).hasPrefix(" ") {
                return Line(text: String(source.dropFirst(hashes + 1)), heading: hashes, code: false, quote: false)
            }
            let quote = source.hasPrefix("> ")
            var body = quote ? String(source.dropFirst(2)) : source
            if body.hasPrefix("- ") || body.hasPrefix("* ") { body = "• " + body.dropFirst(2) }
            return Line(text: body, heading: 0, code: false, quote: quote)
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.lines(text).enumerated()), id: \.offset) { _, line in
                    Text(line.code ? AttributedString(line.text) : (try? AttributedString(markdown: line.text,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line.text))
                        .font(line.code ? .system(size: 13, design: .monospaced) : line.heading > 0 ? .system(size: CGFloat(26 - line.heading * 2), weight: .semibold) : .body)
                        .foregroundStyle(line.quote ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .foregroundStyle(.primary)
        // A preview displays links but never dispatches URLs to external handlers.
        .environment(\.openURL, OpenURLAction { _ in .handled })
    }
}
