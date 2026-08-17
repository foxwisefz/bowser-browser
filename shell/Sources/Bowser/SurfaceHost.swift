import AppKit
import SwiftUI

/// ADR 0009: mods own surfaces — native windows whose content is a
/// declarative view tree sent as JSON from Elixir, rendered as SwiftUI.
/// Look: borderless translucent HUD panels (vibrancy material adapts to
/// light/dark automatically), rounded corners, hover rows, gradient accent
/// for active state. Drag anywhere to move.
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
                width: message["width"] as? Double ?? 240,
                tree: tree
            )
        case "close":
            guard let id = message["id"] as? String else { return }
            panels.removeValue(forKey: id)?.close()
        default:
            NSLog("Bowser: unknown surface op")
        }
    }

    private func show(id: String, title: String, anchor: String, width: Double, tree: [String: Any]) {
        let root = SurfaceRootView(surfaceId: id, title: title, node: tree)

        if let panel = panels[id],
           let effect = panel.contentView as? NSVisualEffectView {
            let hosting = NSHostingView(rootView: root)
            hosting.autoresizingMask = [.width, .height]
            effect.subviews.forEach { $0.removeFromSuperview() }
            let size = NSSize(width: width, height: hosting.fittingSize.height)
            panel.setContentSize(size)
            hosting.frame = effect.bounds
            effect.addSubview(hosting)
            return
        }

        let hosting = NSHostingView(rootView: root)
        let height = max(60, hosting.fittingSize.height)

        let panel = SurfacePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        let effect = NSVisualEffectView(frame: panel.contentLayoutRect)
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        effect.autoresizingMask = [.width, .height]

        hosting.autoresizingMask = [.width, .height]
        hosting.frame = effect.bounds
        effect.addSubview(hosting)
        panel.contentView = effect

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
        let drop = 40 + CGFloat(panels.count) * (size.height + 20)
        switch anchor {
        case "left_of_main":
            panel.setFrameOrigin(NSPoint(x: frame.minX - size.width - 14, y: frame.maxY - size.height - drop))
        case "right_of_main":
            panel.setFrameOrigin(NSPoint(x: frame.maxX + 14, y: frame.maxY - size.height - drop))
        default:
            panel.center()
        }
    }
}

/// Borderless panels refuse key status by default; allow it so text fields
/// in palettes can be edited (becomesKeyOnlyIfNeeded keeps buttons from
/// stealing focus).
private final class SurfacePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Root chrome (title + tree)

struct SurfaceRootView: View {
    let surfaceId: String
    let title: String
    let node: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .kerning(1.1)
                .foregroundStyle(.secondary)
            SurfaceTreeView(surfaceId: surfaceId, node: node)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The view-tree interpreter

struct SurfaceTreeView: View {
    let surfaceId: String
    let node: [String: Any]

    var body: some View {
        render(node)
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
            let spacing = node["spacing"] as? Double ?? 4
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
            switch style {
            case "title":
                return AnyView(
                    Text(value)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                )
            case "caption":
                return AnyView(
                    Text(value).font(.system(size: 11)).foregroundStyle(.secondary)
                )
            default:
                return AnyView(Text(value).font(.system(size: 13)))
            }
        case "button":
            return AnyView(SurfaceRow(node: node, emit: emit))
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
            return AnyView(
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
                    .padding(.vertical, 5)
                    .opacity(0.6)
            )
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

/// A palette row: quiet at rest, soft highlight on hover, gradient accent
/// fill when active. Explicit colors throughout — non-key panels dim
/// standard control styles to gray, so we never rely on them.
private struct SurfaceRow: View {
    let node: [String: Any]
    let emit: (String, Any?) -> Void

    @State private var hovering = false

    private var active: Bool { node["active"] as? Bool ?? false }
    private var indent: Double { node["indent"] as? Double ?? 0 }

    var body: some View {
        Button(action: { emit(node["event"] as? String ?? "click", node["payload"]) }) {
            HStack(spacing: 8) {
                if let symbol = node["symbol"] as? String {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                }
                Text(node["label"] as? String ?? "?")
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(
            Group {
                if active {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 1)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.08))
                }
            }
        )
        .onHover { hovering = $0 }
        .padding(.leading, indent)
        .animation(.easeOut(duration: 0.12), value: hovering)
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
        VStack(alignment: .leading, spacing: 3) {
            if let label {
                Text(label.uppercased())
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: min...max) { editing in
                if !editing { emit(eventId, value) }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
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
            .font(.system(size: 12))
            .onSubmit { emit(eventId, text) }
            .padding(.horizontal, 9)
            .onAppear {
                if !loaded {
                    text = initial
                    loaded = true
                }
            }
    }
}
