import BowserSurfaceKit
import AppKit
import SwiftUI
// MARK: - Root chrome (title + tree)

struct SurfaceRootView: View {
    @Environment(\.surfaceDispatch) private var dispatch
    let surfaceId: String
    let title: String
    let node: [String: Any]

    var body: some View {
        panelContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
    }

    var panelContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .kerning(1.1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(action: {
                    dispatch(["op": "event", "event": "surface_dismiss", "surface": surfaceId])
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (View menu re-opens it)")
            }
            SurfaceTreeView(surfaceId: surfaceId, node: node)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)

    }
}

// MARK: - The view-tree interpreter

struct SurfaceTreeView: View {
    @Environment(\.surfaceDispatch) private var dispatch
    var colors = SurfaceColors()
    let surfaceId: String
    let node: [String: Any]
    /// Edge panels supply their AppKit tracker. All other surface roots
    /// still need a cursor environment for magnify_strip (including Settings).
    var cursor: CursorModel? = nil
    var eventWebview: UInt64? = nil
    @StateObject private var localCursor = CursorModel()
    @Environment(\.surfaceEventWebview) private var inheritedWebview

    var body: some View {
        render(node)
            .disabled(node["disabled"] as? Bool ?? false)
            .modifier(SurfaceNodeStyle(node: node))
            .modifier(SurfacePaletteScope(palette: node["palette"] as? [String: Any]))
            .environmentObject(cursor ?? localCursor)
            .environment(\.surfaceEventWebview, eventWebview ?? inheritedWebview)
    }

    private func scopedColor(_ value: Any?, fallback: String = "text") -> Color {
        let local = node["palette"] as? [String: Any] ?? [:]
        let palette = SurfaceColorSpec.validPalette(local)
            ? colors.palette.merging(local) { _, replacement in replacement } : colors.palette
        return Color(nsColor: SurfaceColorSpec.resolve(value, palette: palette,
            dark: colors.scheme == .dark, highContrast: colors.contrast == .increased, fallback: fallback))
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
        if let id = eventWebview ?? inheritedWebview { message["webview"] = id }
        dispatch(message)
    }

    private func render(_ node: [String: Any]) -> AnyView {
        switch node["t"] as? String ?? "" {
        case "palette":
            return AnyView(SurfaceTreeView(surfaceId: surfaceId, node: node["content"] as? [String: Any] ?? [:]))
        case "vstack":
            let spacing = node["spacing"] as? Double ?? 4
            return AnyView(VStack(alignment: SurfaceNodeStyle.horizontal(node["alignment"] as? String), spacing: spacing) {
                ForEach(SurfaceNode.children(children(node))) { child in
                    SurfaceTreeView(surfaceId: surfaceId, node: child.value)
                }
            })
        case "hstack":
            let spacing = node["spacing"] as? Double ?? 8
            return AnyView(HStack(spacing: spacing) {
                ForEach(SurfaceNode.children(children(node))) { child in
                    SurfaceTreeView(surfaceId: surfaceId, node: child.value)
                }
            })
        case "form", "state":
            return AnyView(SurfaceModelScope(surfaceId: surfaceId, node: node))
        case "editor", "preview", "selector", "switch":
            return AnyView(SurfaceBoundView(surfaceId: surfaceId, node: node))
        case "flow":
            return AnyView(SurfaceFlowLayout(spacing: node["spacing"] as? Double ?? 6) {
                ForEach(SurfaceNode.children(children(node))) { child in
                    SurfaceTreeView(surfaceId: surfaceId, node: child.value)
                }
            })
        case "input":
            return AnyView(SurfaceInput(node: node))
        case "action":
            return AnyView(SurfaceNativeAction(node: node, emit: emit))
        case "sheet", "popover":
            return AnyView(SurfacePresentation(surfaceId: surfaceId, node: node))
        case "list_detail":
            return AnyView(SurfaceListDetail(surfaceId: surfaceId, node: node))
        case "grid":
            return AnyView(LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: node["spacing"] as? Double ?? 12), count: max(1, min(12, node["columns"] as? Int ?? 2))), spacing: node["spacing"] as? Double ?? 12) {
                ForEach(SurfaceNode.children(children(node))) { child in
                    SurfaceTreeView(surfaceId: surfaceId, node: child.value)
                }
            })
        case "fields":
            return AnyView(Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                ForEach(SurfaceNode.children(children(node))) { child in
                    GridRow {
                        Text(child.value["label"] as? String ?? "").gridColumnAlignment(.trailing)
                        SurfaceTreeView(surfaceId: surfaceId, node: child.value["content"] as? [String: Any] ?? [:])
                    }
                }
            })
        case "group":
            return AnyView(GroupBox(node["label"] as? String ?? "") {
                SurfaceTreeView(surfaceId: surfaceId, node: node["content"] as? [String: Any] ?? [:]).padding(12)
            })
        case "text":
            let value = node["value"] as? String ?? ""
            let style = node["style"] as? String
            if let size = node["font_size"] as? Double { return AnyView(Text(value).font(.system(size: max(8, min(72, size))))) }
            switch style {
            case "heading":
                return AnyView(Text(value).font(.title2.weight(.semibold)))
            case "body":
                return AnyView(Text(value).font(.body))
            case "title":
                return AnyView(
                    Text(value)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                )
            case "caption":
                return AnyView(
                    Text(value).font(.system(size: 11)).foregroundStyle(scopedColor("secondary_text"))
                )
            case "mono":
                // One-line log entry: what an agent said / which tool it called.
                return AnyView(
                    Text(value)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(scopedColor("secondary_text"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                )
            default:
                return AnyView(Text(value).font(.system(size: 13)))
            }
        case "button":
            return AnyView(SurfaceRow(node: node, emit: emit))
        case "row":
            return AnyView(SurfaceListRow(node: node, emit: emit, render: { AnyView(SurfaceTreeView(surfaceId: surfaceId, node: $0)) }))
        case "toggle":
            return AnyView(SurfaceToggle(
                eventId: node["event"] as? String ?? "toggle",
                initial: node["on"] as? Bool ?? false,
                payload: node["payload"],
                label: node["label"] as? String ?? "",
                emit: emit
            ))
        case "section":
            return AnyView(
                Text((node["value"] as? String ?? "").uppercased())
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .kerning(0.9)
                    .foregroundStyle(scopedColor("secondary_text"))
                    .padding(.top, 10)
                    .padding(.bottom, 2)
            )
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
                surfaceId: surfaceId,
                eventId: eventId,
                placeholder: node["placeholder"] as? String ?? "",
                initial: node["value"] as? String ?? "",
                emit: emit
            ).id(eventId))
        case "colorpicker":
            return AnyView(SurfaceColorPicker(
                eventId: node["event"] as? String ?? "color",
                initialHex: node["value"] as? String,
                label: node["label"] as? String ?? "",
                emit: emit
            ).id(node["event"] as? String ?? "color"))
        case "divider":
            if node["axis"] as? String == "vertical" { return AnyView(Divider()) }
            return AnyView(
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
                    .padding(.vertical, 5)
                    .opacity(0.6)
            )
        case "spacer":
            return AnyView(Spacer(minLength: node["min"] as? Double ?? 0))
        case "profile_avatar", "profile_name":
            return AnyView(SurfaceProfileValue(node: node))
        case "profile_curve":
            return AnyView(CurvedProfileLabel(profileID: node["profile_id"] as? String ?? "default"))
        case "magnify_strip":
            return AnyView(MagnifyStripView(surfaceId: surfaceId, node: node, emit: emit,
                                           tracksLocally: cursor == nil))
        case "particles":
            return AnyView(ParticlesNodeView(
                chars: node["chars"] as? [String] ?? ["♪", "♫", "♩", "♬"],
                rate: node["rate"] as? Double ?? 2.5,
                active: node["active"] as? Bool ?? true
            ))
        case "image":
            if let path = node["path"] as? String, let image = ImageCache.load(path) {
                let size = node["size"] as? Double ?? 16
                return AnyView(
                    Image(nsImage: image).resizable().frame(width: size, height: size)
                )
            }
            let symbol = node["symbol"] as? String ?? "questionmark"
            return AnyView(Image(systemName: symbol))
        case let unknown:
            return AnyView(
                Text("⟨unknown widget: \(unknown)⟩")
                    .font(.caption)
                    .foregroundStyle(scopedColor("error"))
            )
        }
    }
}

/// A palette row: quiet at rest, dims on press, gradient accent fill when
/// active. NO hover state — non-activating panels drop mouse-exit events,
/// so hover highlights stick; press feedback is synchronous and can't.
/// Explicit colors throughout — non-key panels dim standard control styles.
private struct SurfaceRow: View {
    let node: [String: Any]
    let emit: (String, Any?) -> Void

    private var active: Bool { node["active"] as? Bool ?? false }
    private var indent: Double { node["indent"] as? Double ?? 0 }
    private var compact: Bool { node["compact"] as? Bool ?? false }

    var body: some View {
        Button(action: { emit(node["event"] as? String ?? "click", node["payload"]) }) {
            HStack(spacing: 8) {
                if let symbol = node["symbol"] as? String {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                }
                Text(node["label"] as? String ?? "?")
                    .font(.system(size: compact ? 11.5 : 13, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                if !compact { Spacer(minLength: 0) }
            }
        }
        .buttonStyle(PaletteRowStyle(active: active, compact: compact))
        .padding(.leading, indent)
    }
}

private struct PaletteRowStyle: ButtonStyle {
    let active: Bool
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, compact ? 2 : 5)
            .padding(.horizontal, compact ? 7 : 9)
            // Compact buttons hug their label (they sit in row trailings);
            // full rows stretch.
            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor)
                } else if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.12))
                }
            }
            .opacity(configuration.isPressed && active ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Left-edge notch: concave shoulders flow out of the screen edge into
/// rounded outer corners. The straight left side stays flush with the screen.
struct DockNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let shoulder = min(18.0, rect.height / 4, rect.width / 3)
        let corner = min(22.0, rect.height / 4, rect.width / 2)
        let x = rect.minX, y = rect.minY, right = rect.maxX, bottom = rect.maxY
        let k = 0.5522847498
        var path = Path()
        path.move(to: CGPoint(x: x, y: y))
        path.addCurve(to: CGPoint(x: x + shoulder, y: y + shoulder),
                      control1: CGPoint(x: x, y: y + shoulder * k),
                      control2: CGPoint(x: x + shoulder * (1 - k), y: y + shoulder))
        path.addLine(to: CGPoint(x: right - corner, y: y + shoulder))
        path.addCurve(to: CGPoint(x: right, y: y + shoulder + corner),
                      control1: CGPoint(x: right - corner * (1 - k), y: y + shoulder),
                      control2: CGPoint(x: right, y: y + shoulder + corner * (1 - k)))
        path.addLine(to: CGPoint(x: right, y: bottom - shoulder - corner))
        path.addCurve(to: CGPoint(x: right - corner, y: bottom - shoulder),
                      control1: CGPoint(x: right, y: bottom - shoulder - corner * (1 - k)),
                      control2: CGPoint(x: right - corner * (1 - k), y: bottom - shoulder))
        path.addLine(to: CGPoint(x: x + shoulder, y: bottom - shoulder))
        path.addCurve(to: CGPoint(x: x, y: bottom),
                      control1: CGPoint(x: x + shoulder * (1 - k), y: bottom - shoulder),
                      control2: CGPoint(x: x, y: bottom - shoulder * k))
        path.closeSubpath()
        return path
    }
}

/// Proximity-magnification icon strip — the physics half of dock-like UIs.
/// Mods supply items (icons + ids); this widget owns cursor tracking and
/// distance-falloff scaling natively, emitting only discrete select events.
/// Reads cursor position from the edge surface's CursorModel.
struct MagnifyStripView: View {
    let surfaceId: String
    let node: [String: Any]
    let emit: (String, Any?) -> Void
    var tracksLocally = false

    @EnvironmentObject var cursor: CursorModel
    @Environment(\.colorScheme) private var colorScheme

    // Dock bounce (bowser-browser-r0g): when the active item changes, the
    // newly active icon hops outward once. The stamp is the animation
    // trigger; inactive items are guarded to zero offset so losing
    // activation never twitches.
    @State private var bounceStamp = 0
    @ObservedObject private var dragPreview = TabDragPreview.shared
    // Slots are ordinary live surface trees; the strip only reserves geometry.
    private var header: [String: Any]? { node["header"] as? [String: Any] }
    private var footer: [String: Any]? { node["footer"] as? [String: Any] }
    private var headerOutside: Bool { node["header_outside"] as? Bool == true }
    private var headerHeight: CGFloat { header == nil ? 0 : min(240, max(0, node["header_height"] as? Double ?? 48)) }
    private var footerHeight: CGFloat { footer == nil ? 0 : min(240, max(0, node["footer_height"] as? Double ?? 48)) }
    private var notch: Bool { (node["chrome"] as? String ?? (surfaceId == "edge_dock" ? "notch" : "none")) == "notch" }

    private var items: [[String: Any]] { node["items"] as? [[String: Any]] ?? [] }

    private struct StripItem: Identifiable {
        let id: String
        let index: Int
        let value: [String: Any]
    }
    private var identifiedItems: [StripItem] {
        items.enumerated().map { StripItem(id: $0.element["id"] as? String ?? "row-\($0.offset)", index: $0.offset, value: $0.element) }
    }

    private var activeId: String? {
        items.first(where: { ($0["active"] as? Bool) == true })?["id"] as? String
    }
    private var baseSize: CGFloat { CGFloat(node["size"] as? Double ?? 28) }
    // Clamped: it's a scale MULTIPLIER (2.0 = double size), and a mod
    // passing pixels here (it happened) must not explode the layout.
    private var magnify: CGFloat { min(3.0, max(1.0, CGFloat(node["magnify"] as? Double ?? 1.9))) }
    private var eventId: String { node["event"] as? String ?? "select" }
    private var spacing: CGFloat { max(0, CGFloat(node["spacing"] as? Double ?? 8)) }
    private let topPad: CGFloat = 12

    /// Vertical origin of the icon block: centered in the view, clamping
    /// back to top-aligned when the strip overflows (bowser-browser-2c8).
    /// The SAME value feeds layout and the magnification row centers so
    /// hover targets stay aligned.
    static func centeredTop(
        viewHeight: CGFloat, count: Int, size: CGFloat, spacing: CGFloat, minPad: CGFloat, headerHeight: CGFloat = 0, footerHeight: CGFloat = 0
    ) -> CGFloat {
        let content = max(0, CGFloat(count) * (size + spacing) - spacing)
        return max(minPad, (viewHeight - content - headerHeight - footerHeight) / 2) + headerHeight
    }

    private func scale(forRow index: Int, top: CGFloat) -> CGFloat {
        if surfaceId == "edge_dock", dragPreview.source != nil { return 1 }
        guard let point = cursor.point else { return 1 }
        let slot = baseSize + spacing
        let center = top + CGFloat(index) * slot + baseSize / 2
        let distance = abs(point.y - center)
        let radius = baseSize * 2.6
        guard distance < radius else { return 1 }
        return 1 + (magnify - 1) * (1 - distance / radius)
    }

    var body: some View {
        GeometryReader { geo in
            let top = Self.centeredTop(
                viewHeight: geo.size.height, count: items.count,
                size: baseSize, spacing: spacing, minPad: topPad, headerHeight: headerHeight, footerHeight: footerHeight
            )
            let contentHeight = items.indices.reduce(CGFloat.zero) {
                $0 + baseSize * scale(forRow: $1, top: top)
            } + CGFloat(max(0, items.count - 1)) * spacing
            ZStack(alignment: .topLeading) {
                if notch, !items.isEmpty {
                    DockNotchShape()
                        .fill(SurfaceServices.color(hex: node["background"] as? String).map { Color(nsColor: $0) } ?? .black)
                        .frame(width: geo.size.width, height: contentHeight + (surfaceId == "edge_dock" && dragPreview.target != nil ? baseSize + spacing : 0) + (headerOutside ? 0 : headerHeight) + footerHeight + 64)
                        .offset(y: top - (headerOutside ? 0 : headerHeight) - 32)
                        .allowsHitTesting(false)
                }
                if let header, !items.isEmpty {
                    SurfaceTreeView(surfaceId: surfaceId, node: header)
                        .frame(width: geo.size.width, height: headerHeight)
                        .offset(y: top - headerHeight)
                }
                if let footer, !items.isEmpty {
                    SurfaceTreeView(surfaceId: surfaceId, node: footer)
                        .frame(width: geo.size.width, height: footerHeight)
                        .offset(y: top + contentHeight)
                }
                VStack(spacing: spacing) {
                    ForEach(identifiedItems) { entry in
                        let index = entry.index
                        let item = entry.value
                        let s = scale(forRow: index, top: top)
                        let active = item["active"] as? Bool ?? false
                        Button(action: { emit(eventId, item["id"]) }) {
                            ZStack {
                                if active {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(.white.opacity(0.16))
                                        .frame(width: min(baseSize * s + 8, geo.size.width - 2),
                                               height: baseSize * s + 8)
                                }
                                icon(for: item)
                                    .frame(width: baseSize * s, height: baseSize * s)
                                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                                if active {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                        .frame(width: min(baseSize * s + 8, geo.size.width - 2),
                                               height: baseSize * s + 8)
                                }
                            }
                            .frame(height: baseSize * s)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .opacity(surfaceId == "edge_dock" && UInt64(entry.id) == dragPreview.source && dragPreview.source != nil ? 0.25 : 1)
                        .padding(.top, surfaceId == "edge_dock" ? dragPreview.gap(for: UInt64(entry.id) ?? 0, after: false, size: baseSize + spacing) : 0)
                        .padding(.bottom, surfaceId == "edge_dock" ? dragPreview.gap(for: UInt64(entry.id) ?? 0, after: true, size: baseSize + spacing) : 0)
                        .animation(.easeOut(duration: 0.16), value: dragPreview.target)
                        .overlay {
                            if surfaceId == "edge_dock", let id = item["id"] as? String,
                               let webviewID = UInt64(id) {
                                SurfaceDragTarget(webviewID: webviewID) { emit(eventId, item["id"]) }.id(webviewID)
                            }
                        }
                        .help(item["title"] as? String ?? "")
                        .accessibilityValue(active ? "Active tab" : "")
                        .animation(.easeOut(duration: 0.09), value: cursor.point)
                        // The hop: out fast, settle back springy. The left-edge
                        // dock bounces rightward, into the page.
                        .phaseAnimator([false, true], trigger: active ? bounceStamp : -1) { content, out in
                            content.offset(x: out && active ? (surfaceId == "edge_dock" ? 4 : 10) : 0)
                        } animation: { out in
                            out ? .spring(duration: 0.15, bounce: 0.4)
                                : .spring(duration: 0.45, bounce: 0.65)
                        }
                    }
                }
                .padding(.top, top)
                .frame(maxWidth: .infinity, alignment: .top)
                .onChange(of: activeId) { _, newValue in
                    if newValue != nil { bounceStamp += 1 }
                }
            }
            .environment(\.colorScheme, surfaceId == "edge_dock" ? .dark : colorScheme)
        }
        .onContinuousHover { phase in
            // Edge panels keep their reliable AppKit mouse tracking. Other
            // panels track in the strip's own coordinates, even when nested.
            guard tracksLocally else { return }
            switch phase {
            case .active(let point): cursor.point = point
            case .ended: cursor.point = nil
            }
        }
    }

    @ViewBuilder
    private func icon(for item: [String: Any]) -> some View {
        // Keep profile identity as a small dot without outlining the artwork.
        let ring = SurfaceServices.color(hex: item["tint"] as? String)
        Group {
            if let path = item["path"] as? String, let image = ImageCache.load(path) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .scaledToFit()
                    // Worker tiles contain 100px outer padding per side.
                    // Remove it in this compact strip, not in saved app icons.
                    .scaleEffect(surfaceId == "edge_dock" && path.contains("/favicons/tiles-v2/") ? 1024.0 / 824.0 : 1)
                    .clipped()
            } else {
                Image(systemName: item["symbol"] as? String ?? "globe")
                    .resizable().scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let ring {
                Circle().fill(Color(nsColor: ring)).frame(width: 4, height: 4)
                    .padding(2)
            }
        }
    }
}

/// Small profile name following the outside of the 48pt notch's upper shoulder.
struct CurvedProfileLabel: View {
    let profileID: String
    @ObservedObject private var profiles = SurfaceServices.shared
    private var name: String {
        if profileID == "default" { return "Default" }
        return profiles.profiles.first { $0.id == profileID }?.name ?? profileID
    }

    var body: some View {
        Canvas { context, _ in
            let letters = Array(name.count > 8 ? String(name.prefix(7)) + "…" : name)
            let font = Font.system(size: 9, weight: .regular)
            let glyphs = letters.map { context.resolve(Text(String($0)).font(font).foregroundStyle(Color.white.opacity(0.8))) }
            let widths = glyphs.map { $0.measure(in: CGSize(width: 100, height: 20)).width + 0.25 }
            let points = Self.shoulder
            var distances: [CGFloat] = [0]
            for i in 1..<points.count {
                distances.append(distances.last! + hypot(points[i].x - points[i-1].x, points[i].y - points[i-1].y))
            }
            let total = widths.reduce(0, +)
            let scale = min(1, (distances.last! - 4) / max(total, 1))
            var advance = (distances.last! - total * scale) / 2
            for i in glyphs.indices {
                let distance = advance + widths[i] * scale / 2
                let j = max(1, distances.firstIndex(where: { $0 >= distance }) ?? (points.count - 1))
                let a = points[j-1], b = points[j]
                let angle = atan2(b.y - a.y, b.x - a.x)
                let fraction = (distance - distances[j-1]) / max(0.001, distances[j] - distances[j-1])
                var glyphContext = context
                glyphContext.addFilter(.shadow(color: .black.opacity(0.85), radius: 1, y: 0.5))
                glyphContext.translateBy(x: 8 + a.x + (b.x-a.x)*fraction + sin(angle)*7,
                                         y: a.y + (b.y-a.y)*fraction - cos(angle)*7)
                glyphContext.rotate(by: .radians(angle))
                glyphContext.scaleBy(x: scale, y: scale)
                glyphContext.draw(glyphs[i], at: .zero, anchor: .center)
                advance += widths[i] * scale
            }
        }
        .frame(width: 64, height: 64)
        .accessibilityLabel("Profile: \(name)")
        .help("Profile: \(name)")
    }

    // Same 16pt concave shoulder and 22pt outer corner as DockNotchShape
    // at the tab deck's 48pt width. Start after the steep screen-edge turn.
    private static let shoulder: [CGPoint] = {
        var points: [CGPoint] = []
        for i in 0...30 {
            let a = Double.pi * (0.75 - Double(i)/120)
            points.append(CGPoint(x: 16 + 16*cos(a), y: 16*sin(a)))
        }
        for i in 1...20 { points.append(CGPoint(x: 16 + Double(i)/2, y: 16)) }
        for i in 1...24 {
            let a = -Double.pi/2 + Double(i)/60 * Double.pi/2
            points.append(CGPoint(x: 26 + 22*cos(a), y: 38 + 22*sin(a)))
        }
        return points
    }()
}

/// Profile data bindings, composable with the same stacks/actions as other UI.
struct SurfaceProfileValue: View {
    let node: [String: Any]
    @ObservedObject private var profiles = SurfaceServices.shared
    private var profile: SurfaceProfile? { profiles.profiles.first { $0.id == node["profile_id"] as? String } }
    private var size: CGFloat { min(128, max(8, node["size"] as? Double ?? 22)) }
    private var badge: Bool { node["t"] as? String == "profile_avatar" && node["badge"] as? Bool == true }
    var body: some View {
        if let profile {
            Group {
                if node["t"] as? String == "profile_name" {
                    Text(profile.name).font(.system(size: size, weight: .medium))
                        .lineLimit(1).truncationMode(.tail)
                } else if let avatar = profile.avatar {
                    SurfaceServices.shared.portrait(avatar, size)
                } else if let icon = profile.icon {
                    Text(icon).font(.system(size: size * 0.85)).frame(width: size, height: size)
                } else {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: size))
                }
            }
            .padding(badge ? 7 : 0)
            .background {
                if badge {
                    Circle().fill(.black)
                        .overlay(Circle().strokeBorder(
                            Color(nsColor: SurfaceServices.color(hex: profile.tint) ?? .gray).opacity(0.55), lineWidth: 1))
                }
            }
            .foregroundStyle(SurfaceServices.color(hex: node["color"] as? String).map { Color(nsColor: $0) } ?? .primary)
            .help("Profile: \(profile.name)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Profile: \(profile.name)")
        }
    }
}

/// Floating-particle emitter (e.g. music notes rising from the toolbar).
/// Stateless: each spawn "slot" k (k = floor(t·rate)) derives its particle
/// deterministically from a hash of k, so the Canvas just draws every slot
/// whose particle is currently mid-flight — no per-frame state churn.
private struct ParticlesNodeView: View {
    let chars: [String]
    let rate: Double
    let active: Bool

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func hash(_ k: Int, _ salt: Double) -> Double {
        let x = sin(Double(k) * 12.9898 + salt * 78.233) * 43758.5453
        return x - floor(x)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { timeline in
            Canvas { context, size in
                guard active, !chars.isEmpty else { return }
                let now = timeline.date.timeIntervalSince(Self.epoch)
                let maxDuration = 3.5
                let firstSlot = Int((now - maxDuration) * rate)
                let lastSlot = Int(now * rate)

                for slot in firstSlot...lastSlot {
                    let born = Double(slot) / rate + hash(slot, 5) * (1 / rate)
                    let duration = 2.0 + hash(slot, 1) * 1.5
                    let t = (now - born) / duration
                    guard t > 0, t < 1 else { continue }

                    let x = hash(slot, 2) * size.width
                    let drift = (hash(slot, 3) - 0.5) * 60
                    let y = size.height - t * (size.height + 24)
                    let opacity = t < 0.15 ? t / 0.15 : 1 - t
                    let char = chars[abs(slot) % chars.count]
                    let fontSize = 11 + hash(slot, 4) * 10

                    let text = Text(verbatim: char)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(Color(
                            hue: hash(slot, 6), saturation: 0.75, brightness: 0.95
                        ))
                    var ctx = context
                    ctx.opacity = opacity
                    ctx.translateBy(x: x + drift * t, y: y)
                    ctx.rotate(by: .degrees((hash(slot, 7) - 0.5) * 40 * t))
                    ctx.draw(ctx.resolve(text), at: .zero)
                }
            }
        }
        .allowsHitTesting(false)
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
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label {
                Text(label.uppercased())
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: min...max) { editing in
                self.editing = editing
                if !editing { emit(eventId, value) }
            }
            .onChange(of: initial) { _, new in if !editing { value = new } }
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

/// Native ColorPicker. Emits "#rrggbb" 350ms after the last change, so a
/// drag across the wheel is one event and the brain can persist without
/// re-rendering (a rebuild mid-drag would close the popover).
struct SurfaceColorPicker: View {
    let eventId: String
    let initialHex: String?
    let label: String
    let emit: (String, Any?) -> Void

    @State private var color: Color
    @State private var pending: Task<Void, Never>?

    init(eventId: String, initialHex: String?, label: String, emit: @escaping (String, Any?) -> Void) {
        self.eventId = eventId; self.initialHex = initialHex; self.label = label; self.emit = emit
        _color = State(initialValue: Color(nsColor: SurfaceServices.color(hex: initialHex) ?? .systemGray))
    }

    /// "#rrggbb" for a color, in sRGB. Pure — tested.
    nonisolated static func hex(_ nsColor: NSColor) -> String {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        func byte(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    var body: some View {
        ColorPicker(label, selection: Binding(get: { color }, set: { newValue in
            color = newValue
            pending?.cancel()
            let hex = Self.hex(NSColor(newValue))
            pending = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                if !Task.isCancelled { emit(eventId, hex); pending = nil }
            }
        }), supportsOpacity: false)
            .font(.system(size: 12))
            .onChange(of: initialHex) { _, new in
                if pending == nil { color = Color(nsColor: SurfaceServices.color(hex: new) ?? .systemGray) }
            }
            .onDisappear { pending?.cancel(); pending = nil }
    }
}

/// icon · title / subtitle · trailing controls. A subtitle stays one line;
/// trailing nodes are laid out by the same renderer (toggle, buttons, a
/// compact textfield).
private struct SurfaceListRow: View {
    var colors = SurfaceColors()
    let node: [String: Any]
    let emit: (String, Any?) -> Void
    let render: ([String: Any]) -> AnyView

    var body: some View {
        let trailing = node["trailing"] as? [[String: Any]] ?? []
        let content = HStack(alignment: .center, spacing: 10) {
            if let hex = node["swatch"] as? String, let color = SurfaceServices.color(hex: hex) {
                Circle().fill(Color(nsColor: color)).frame(width: 12, height: 12)
            } else if let path = node["path"] as? String, let image = ImageCache.load(path) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
            } else if let symbol = node["symbol"] as? String {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(colors.color("secondary_text")).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(node["title"] as? String ?? "").font(.system(size: 13)).lineLimit(1)
                if let subtitle = node["subtitle"] as? String, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(colors.color("secondary_text"))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            ForEach(SurfaceNode.children(trailing)) { child in
                render(child.value)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        Group {
            if let eventId = node["event"] as? String {
                Button(action: { emit(eventId, node["payload"]) }) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(colors.color("separator")).frame(height: 0.5).opacity(0.6)
        }
    }
}

/// A macOS switch. Emits its new value on change (with payload, when given,
/// as {"on": bool, "payload": …} so one event id can serve a list).
struct SurfaceToggle: View {
    let eventId: String
    let initial: Bool
    let payload: Any?
    let label: String
    let emit: (String, Any?) -> Void

    @State private var on: Bool

    init(eventId: String, initial: Bool, payload: Any?, label: String, emit: @escaping (String, Any?) -> Void) {
        self.eventId = eventId
        self.initial = initial
        self.payload = payload
        self.label = label
        self.emit = emit
        // Seeded at init, NOT in onAppear: assigning state on appear fired
        // onChange with the initial value, so every render of a list of
        // switches "toggled" every row — it flipped mods on and off.
        _on = State(initialValue: initial)
    }

    var body: some View {
        Toggle(label, isOn: Binding(get: { on }, set: { value in
            on = value
            if let payload { emit(eventId, ["on": value, "payload": payload]) }
            else { emit(eventId, value) }
        }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .onChange(of: initial) { _, value in on = value }
    }
}

private struct SurfaceTextField: View {
    let eventId: String
    let placeholder: String
    let initial: String
    let emit: (String, Any?) -> Void
    @StateObject private var model: SurfaceFormModel
    init(surfaceId: String, eventId: String, placeholder: String, initial: String, emit: @escaping (String, Any?) -> Void) {
        self.eventId = eventId; self.placeholder = placeholder; self.initial = initial; self.emit = emit
        _model = StateObject(wrappedValue: SurfaceFormStore.shared.model(surface: surfaceId,
            key: "textfield:" + eventId, initial: ["value": initial]))
    }
    private var text: Binding<String> {
        Binding(get: { model.values["value"] as? String ?? "" }, set: { model.values["value"] = $0 })
    }
    var body: some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .onSubmit { emit(eventId, text.wrappedValue) }
            .onChange(of: initial) { old, new in if text.wrappedValue == old { text.wrappedValue = new } }
            .padding(.horizontal, 9)
    }
}

/// Test seam for SurfaceColorPicker.hex (the view itself is file-private).
enum SurfaceColorPickerHexBridge {
    nonisolated static func hex(_ color: NSColor) -> String { SurfaceColorPicker.hex(color) }
}

/// The drag session stays in the stable host while its surrounding view changes.
private struct SurfaceDragTarget: NSViewRepresentable {
    let webviewID: UInt64
    let select: () -> Void
    final class Coordinator { var select: () -> Void = {} }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        context.coordinator.select = select
        let coordinator = context.coordinator
        return SurfaceServices.shared.dragView(webviewID) { coordinator.select() }
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.select = select }
}

/// The same tree interpreter supplies the built-in fallback and signed modules.
struct SurfaceGenerationRoot: View {
    @ObservedObject var context: SurfaceRenderContext
    var generation: UInt64 = 0
    let dispatch: @MainActor ([String: Any]) -> Void
    var body: some View {
        Group {
            if let title = context.title {
                if context.panelContentOnly {
                    SurfaceRootView(surfaceId: context.surfaceID, title: title, node: context.node).panelContent
                } else {
                    SurfaceRootView(surfaceId: context.surfaceID, title: title, node: context.node)
                }
            } else {
                SurfaceTreeView(surfaceId: context.surfaceID, node: context.node,
                    cursor: context.cursor, eventWebview: context.eventWebview)
            }
        }
        .foregroundStyle(Color(nsColor: SurfaceColorSpec.resolve(context.style["foreground"], palette: context.palette,
            dark: context.scheme == .dark, highContrast: context.contrast == .increased, fallback: "text")))
        .tint(Color(nsColor: SurfaceColorSpec.resolve(context.style["accent"], palette: context.palette,
            dark: context.scheme == .dark, highContrast: context.contrast == .increased, fallback: "accent")))
        .environment(\.surfaceRenderOwner, context.id)
        .environment(\.surfaceRenderGeneration, generation)
        .environment(\.surfacePalette, context.palette)
        .environment(\.colorScheme, context.scheme)
        .environment(\.surfaceStateNamespace, context.namespace)
        .environment(\.surfaceEventWebview, context.eventWebview)
        .environment(\.surfaceDispatch, dispatch)
    }
}
