import SwiftUI

/// Renders an SDUI node tree into native SwiftUI, resolving each node's
/// `bind` against the current data item (a tweet). This is the whole point:
/// the brain sends a declaration, the phone renders it as REAL views — List,
/// Text, AsyncImage, SF Symbols — never a webview.
struct SDUINodeView: View {
    let node: SDUINode
    let item: JSONValue

    var body: some View {
        switch node.type {
        case "vstack":
            VStack(alignment: .leading, spacing: node.propDouble("spacing").map { CGFloat($0) } ?? 4) {
                children
            }
            .padding(node.propDouble("padding").map { CGFloat($0) } ?? 0)

        case "hstack":
            HStack(spacing: node.propDouble("spacing").map { CGFloat($0) } ?? 6) {
                children
            }
            .padding(.top, node.propDouble("top").map { CGFloat($0) } ?? 0)

        case "zstack":
            ZStack(alignment: zAlignment(node.propString("align"))) {
                children
            }
            .frame(maxWidth: .infinity)
            .clipped()

        case "gradient":
            LinearGradient(
                colors: [.black.opacity(0.75), .black.opacity(0.0)],
                startPoint: .bottom, endPoint: .center
            )
            .frame(height: node.propDouble("height").map { CGFloat($0) } ?? 200)
            .allowsHitTesting(false)

        case "text":
            textView

        case "icon":
            Image(systemName: node.propString("symbol") ?? "questionmark")
                .font(.system(size: node.propDouble("size").map { CGFloat($0) } ?? 15))
                .foregroundStyle(color(node.propString("color")))

        case "image":
            imageView

        case "spacer":
            Spacer(minLength: 0)

        default:
            EmptyView()
        }
    }

    @ViewBuilder private var children: some View {
        ForEach(Array((node.children ?? []).enumerated()), id: \.offset) { _, child in
            SDUINodeView(node: child, item: item)
        }
    }

    // MARK: text

    @ViewBuilder private var textView: some View {
        let raw = node.bind.flatMap { item.resolve($0)?.stringValue } ?? ""
        let value = node.propBool("relative") ? relativeTime(raw) : raw
        if !value.isEmpty {
            Text(value)
                .font(.system(size: node.propDouble("size").map { CGFloat($0) } ?? 15,
                              weight: node.propString("weight") == "bold" ? .semibold : .regular))
                .foregroundStyle(color(node.propString("color")))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: image (optional — nothing if the bound path is empty)

    @ViewBuilder private var imageView: some View {
        if let urlString = node.bind.flatMap({ item.resolve($0)?.stringValue }),
           let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Color.gray.opacity(0.12)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: node.propDouble("height").map { CGFloat($0) } ?? 180)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: node.propDouble("corner").map { CGFloat($0) } ?? 0))
        }
    }

    // MARK: helpers

    private func color(_ name: String?) -> Color {
        switch name {
        case "secondary": return .secondary
        case "white": return .white
        default: return .primary
        }
    }

    private func zAlignment(_ name: String?) -> Alignment {
        switch name {
        case "bottomLeading": return .bottomLeading
        case "bottom": return .bottom
        case "topLeading": return .topLeading
        default: return .center
        }
    }

    private func relativeTime(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
