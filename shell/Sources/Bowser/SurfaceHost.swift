import AppKit
import SwiftUI

/// ADR 0009: mods own surfaces. A surface is a native window/panel whose
/// content is a declarative view tree sent as JSON from Elixir, rendered
/// here as real SwiftUI. Interaction events flow back over the brain socket
/// as {"event": "surface", "surface": id, "id": widgetEvent, "value": ...}.
@MainActor
final class SurfaceManager {
    static let shared = SurfaceManager()

    private var panels: [String: NSPanel] = [:]

    func handle(_ message: [String: Any]) {
        switch message["surface"] as? String {
        case "show":
            guard let id = message["id"] as? String,
                  let tree = message["view"] as? [String: Any] else { return }
            show(
                id: id,
                title: message["title"] as? String ?? id,
                anchor: message["anchor"] as? String ?? "right_of_main",
                width: message["width"] as? Double ?? 260,
                tree: tree
            )
        case "close":
            guard let id = message["id"] as? String else { return }
            close(id: id)
        default:
            NSLog("Bowser: unknown surface op")
        }
    }

    private func show(id: String, title: String, anchor: String, width: Double, tree: [String: Any]) {
        let root = NSHostingView(rootView: SurfaceTreeView(surfaceId: id, node: tree))
        root.setFrameSize(root.fittingSize)

        if let panel = panels[id] {
            panel.title = title
            panel.contentView = root
            panel.setContentSize(NSSize(width: width, height: root.fittingSize.height))
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: max(80, root.fittingSize.height)),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentView = root
        position(panel, anchor: anchor)
        panel.orderFront(nil)
        panels[id] = panel
    }

    private func position(_ panel: NSPanel, anchor: String) {
        guard let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            panel.center()
            return
        }
        let frame = main.frame
        let size = panel.frame.size
        // Cascade so multiple palettes on the same edge don't stack exactly.
        let drop = 40 + CGFloat(panels.count) * (size.height + 24)
        switch anchor {
        case "left_of_main":
            panel.setFrameOrigin(NSPoint(x: frame.minX - size.width - 12, y: frame.maxY - size.height - drop))
        case "right_of_main":
            panel.setFrameOrigin(NSPoint(x: frame.maxX + 12, y: frame.maxY - size.height - drop))
        default:
            panel.center()
        }
    }

    private func close(id: String) {
        panels.removeValue(forKey: id)?.close()
    }
}

// MARK: - The view-tree interpreter

/// Renders one JSON node (recursively). Vocabulary v1: vstack, hstack, text,
/// button, slider, textfield, divider, spacer, image. Unknown nodes render
/// as a visible placeholder so vocabulary gaps are loud, not silent.
struct SurfaceTreeView: View {
    let surfaceId: String
    let node: [String: Any]

    var body: some View {
        render(node)
            .padding(12)
    }

    private func children(_ node: [String: Any]) -> [[String: Any]] {
        node["children"] as? [[String: Any]] ?? []
    }

    private func emit(_ eventId: String, _ value: Any?) {
        var message: [String: Any] = [
            "op": "event", "event": "surface",
            "surface": surfaceId, "id": eventId,
        ]
        if let value { message["value"] = value }
        BrainBridge.shared.send(message)
    }

    private func render(_ node: [String: Any]) -> AnyView {
        switch node["t"] as? String ?? "" {
        case "vstack":
            let spacing = node["spacing"] as? Double ?? 8
            return AnyView(VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(children(node).enumerated()), id: \.offset) { _, child in
                    render(child)
                }
            })
        case "hstack":
            let spacing = node["spacing"] as? Double ?? 8
            return AnyView(HStack(spacing: spacing) {
                ForEach(Array(children(node).enumerated()), id: \.offset) { _, child in
                    render(child)
                }
            })
        case "text":
            let value = node["value"] as? String ?? ""
            let style = node["style"] as? String
            return AnyView(
                Text(value)
                    .font(style == "title" ? .headline : style == "caption" ? .caption : .body)
                    .foregroundStyle(style == "caption" ? .secondary : .primary)
            )
        case "button":
            let label = node["label"] as? String ?? "?"
            let eventId = node["event"] as? String ?? "click"
            let active = node["active"] as? Bool ?? false
            let indent = node["indent"] as? Double ?? 0
            let base = Button(action: { emit(eventId, node["payload"]) }) {
                HStack(spacing: 6) {
                    if let symbol = node["symbol"] as? String {
                        Image(systemName: symbol)
                    }
                    Text(label).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            // Our palettes are non-activating panels: never the key window,
            // and macOS dims standard button styles (incl. borderedProminent)
            // in non-key windows to gray. Active state needs an explicit
            // fill that ignores key-window state.
            if active {
                return AnyView(
                    base
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor))
                        .padding(.leading, indent)
                )
            }
            return AnyView(base.buttonStyle(.bordered).padding(.leading, indent))
        case "slider":
            let eventId = node["event"] as? String ?? "slide"
            return AnyView(SurfaceSlider(
                eventId: eventId,
                min: node["min"] as? Double ?? 0,
                max: node["max"] as? Double ?? 1,
                initial: node["value"] as? Double ?? 0.5,
                label: node["label"] as? String,
                emit: emit
            ))
        case "textfield":
            let eventId = node["event"] as? String ?? "submit"
            return AnyView(SurfaceTextField(
                eventId: eventId,
                placeholder: node["placeholder"] as? String ?? "",
                initial: node["value"] as? String ?? "",
                emit: emit
            ))
        case "divider":
            return AnyView(Divider())
        case "spacer":
            return AnyView(Spacer(minLength: node["min"] as? Double ?? 0))
        case "image":
            let symbol = node["symbol"] as? String ?? "questionmark"
            return AnyView(Image(systemName: symbol))
        case let unknown:
            return AnyView(
                Text("⟨unknown widget: \(unknown)⟩")
                    .font(.caption)
                    .foregroundStyle(.red)
            )
        }
    }
}

private struct SurfaceSlider: View {
    let eventId: String
    let min: Double
    let max: Double
    let initial: Double
    let label: String?
    let emit: (String, Any?) -> Void

    @State private var value = 0.0
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: min...max) { editing in
                if !editing { emit(eventId, value) }
            }
        }
        .onAppear {
            if !loaded {
                value = initial
                loaded = true
            }
        }
    }
}

private struct SurfaceTextField: View {
    let eventId: String
    let placeholder: String
    let initial: String
    let emit: (String, Any?) -> Void

    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .onSubmit { emit(eventId, text) }
            .onAppear {
                if !loaded {
                    text = initial
                    loaded = true
                }
            }
    }
}
