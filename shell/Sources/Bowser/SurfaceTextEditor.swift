import BowserSurfaceKit
import AppKit
import SwiftUI
/// An editor is only an editing surface. Its model owns selection and commands;
/// sibling views decide how to present tools and previews.
struct SurfaceMultilineInput: View {
    var colors = SurfaceColors()
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
                foreground: node["foreground"], background: node["background"])
            if text.isEmpty {
                Text(node["placeholder"] as? String ?? "")
                    .foregroundStyle(colors.color("secondary_text")).padding(16).allowsHitTesting(false)
            }
        }.frame(minHeight: 100, maxHeight: .infinity)
    }
}

/// Text-only Markdown preview: no HTML execution, web views or image fetches.
struct SurfaceMarkdownPreview: View {
    var colors = SurfaceColors()
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
                        .foregroundStyle(colors.color(line.quote ? "secondary_text" : "text"))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(colors.color("editor_background"))
        .foregroundStyle(colors.color("text"))
        // A preview displays links but never dispatches URLs to external handlers.
        .environment(\.openURL, OpenURLAction { _ in .handled })
    }
}
