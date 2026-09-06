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
    private var hostings: [String: NSHostingView<AnyView>] = [:]
    private var activationObserved = false

    /// Floating panels ride above the browser window only while Bowser is
    /// the active app; otherwise they drop to normal level and behave like
    /// ordinary windows of an inactive app (behind whatever is in front,
    /// still there when you come back). Edges/overlays are children of the
    /// main window and need nothing.
    private func observeActivation() {
        guard !activationObserved else { return }
        activationObserved = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setFloatingPanels(level: .normal) }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setFloatingPanels(level: .floating, front: true) }
        }
    }

    private func setFloatingPanels(level: NSWindow.Level, front: Bool = false) {
        // Independent floating panels only: a child window (toolbar overlay,
        // window-attached edge) ordered front raises its PARENT — on app
        // reactivation that shoved the overlay's original window on top.
        for (id, panel) in panels where edgeConfigs[id] == nil && panel.parent == nil {
            panel.level = level
            if front { panel.orderFront(nil) }
        }
    }

    func handle(_ message: [String: Any]) {
        switch message["surface"] as? String {
        case "show":
            guard let id = message["id"] as? String,
                  let tree = message["view"] as? [String: Any] else { return }
            if message["kind"] as? String == "settings" {
                // A section of the Settings window, not a panel. A floating
                // leftover with this id (from before it moved) goes away.
                if let panel = panels.removeValue(forKey: id) {
                    panel.parent?.removeChildWindow(panel)
                    panel.close()
                }
                hostings.removeValue(forKey: id)
                SettingsWindow.shared.set(
                    id: id,
                    title: message["title"] as? String ?? id,
                    order: message["order"] as? Int ?? 50,
                    tree: tree
                )
                if message["activate"] as? Bool == true {
                    SettingsWindow.shared.show(select: id)
                }
                return
            }
            if message["kind"] as? String == "toolbar_overlay" {
                showToolbarOverlay(id: id, tree: tree)
                return
            }
            if message["kind"] as? String == "edge" {
                showEdge(
                    id: id,
                    edge: message["edge"] as? String ?? "left",
                    peek: message["peek"] as? Double ?? 6,
                    width: message["width"] as? Double ?? 72,
                    attach: message["attach"] as? String ?? "window",
                    tree: tree
                )
                return
            }
            show(
                id: id,
                title: message["title"] as? String ?? id,
                anchor: message["anchor"] as? String ?? "right_of_main",
                width: message["width"] as? Double ?? 240,
                tree: tree
            )
        case "close":
            guard let id = message["id"] as? String else { return }
            SettingsWindow.shared.remove(id: id)
            hostings.removeValue(forKey: id)
            overlayHostings.removeValue(forKey: id)
            if let panel = panels.removeValue(forKey: id) {
                panel.parent?.removeChildWindow(panel)
                panel.close()
            }
        default:
            NSLog("Bowser: unknown surface op")
        }
    }

    // MARK: - Toolbar overlay: a click-through child window riding the main
    // window's toolbar region. Effects (particles etc.) render here, over
    // the real chrome.

    private var overlayHostings: [String: NSHostingView<AnyView>] = [:]
    private var overlayObserver: Any?

    private func showToolbarOverlay(id: String, tree: [String: Any]) {
        let root = AnyView(SurfaceTreeView(surfaceId: id, node: tree))

        if let hosting = overlayHostings[id], let panel = panels[id] {
            hosting.rootView = root
            positionOverlay(panel)
            return
        }

        guard let main = NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.windowController is BrowserWindowController })
        else { return }

        let panel = SurfacePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        main.addChildWindow(panel, ordered: .above)
        positionOverlay(panel)
        panels[id] = panel
        overlayHostings[id] = hosting

        if overlayObserver == nil {
            overlayObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    for (oid, _) in SurfaceManager.shared.overlayHostings {
                        if let p = SurfaceManager.shared.panels[oid] {
                            SurfaceManager.shared.positionOverlay(p)
                        }
                    }
                }
            }
        }
    }

    private func positionOverlay(_ panel: NSPanel) {
        guard let parent = panel.parent else { return }
        let height: CGFloat = 64
        panel.setFrame(
            NSRect(
                x: parent.frame.minX,
                y: parent.frame.maxY - height,
                width: parent.frame.width,
                height: height
            ),
            display: true
        )
    }

    // MARK: - Edge surfaces: a child window hugging a window edge, mostly
    // hidden (peek), sliding into view on cursor proximity. The slide is
    // manager physics; whatever renders inside is the mod's tree.

    private var edgeConfigs: [String: (edge: String, peek: Double, width: Double, attach: String)] = [:]
    private var edgeRevealed: Set<String> = []
    private var edgeCursor: [String: CursorModel] = [:]

    private func showEdge(
        id: String, edge: String, peek: Double, width: Double, attach: String, tree: [String: Any]
    ) {
        // A peek under 6px is invisible and unhittable.
        let peek = max(peek, 6)
        edgeConfigs[id] = (edge, peek, width, attach)
        let cursor = edgeCursor[id] ?? CursorModel()
        edgeCursor[id] = cursor
        let root = Self.edgeRoot(surfaceId: id, edge: edge, tree: tree, cursor: cursor)

        if let hosting = overlayHostings[id], let panel = panels[id] {
            hosting.rootView = root
            positionEdge(id: id, panel: panel, animated: false)
            return
        }

        guard let main = NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.windowController is BrowserWindowController })
        else { return }

        let panel = SurfacePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // A fully transparent window lets WindowServer route clicks through
        // transparent favicon pixels before AppKit can hit-test them.
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.01)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false

        let container = EdgeTrackingView(surfaceId: id, cursor: cursor)
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)
        panel.contentView = container

        if attach == "screen" {
            // Screen-edge dock: independent of any window; just float.
            panel.level = .floating
            panel.orderFront(nil)
        } else {
            main.addChildWindow(panel, ordered: .above)
        }
        panels[id] = panel
        overlayHostings[id] = hosting
        positionEdge(id: id, panel: panel, animated: false)
    }

    /// The mod's tree plus the primitive's own affordance: a drawer-handle
    /// capsule pinned to the inner edge, so the collapsed sliver is visible
    /// and inviting. Mod content never needs to know about collapse state.
    private static func edgeRoot(
        surfaceId: String, edge: String, tree: [String: Any], cursor: CursorModel
    ) -> AnyView {
        AnyView(
            ZStack(alignment: edge == "right" ? .leading : .trailing) {
                SurfaceTreeView(surfaceId: surfaceId, node: tree)
                    .environmentObject(cursor)
                Capsule()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 3.5, height: 46)
                    .padding(edge == "right" ? .leading : .trailing, 1.5)
                    .shadow(color: .black.opacity(0.3), radius: 2)
            }
            .frame(maxHeight: .infinity)
        )
    }

    func setEdgeRevealed(_ id: String, _ revealed: Bool) {
        guard let panel = panels[id] else { return }
        if revealed { edgeRevealed.insert(id) } else { edgeRevealed.remove(id) }
        positionEdge(id: id, panel: panel, animated: true)
    }

    /// Tab-switch pulse (bowser-browser-kt2): slide every edge surface out
    /// briefly so in-dock feedback (the active-icon bounce) is actually
    /// visible past the collapsed peek sliver, then retract. Generation
    /// token so overlapping pulses don't collapse early; a cursor already
    /// over the panel wins — retracting under the pointer would fight the
    /// proximity tracking.
    private var pulseGeneration = 0

    func pulseEdges(for seconds: TimeInterval = 1.4) {
        pulseGeneration += 1
        let generation = pulseGeneration
        for id in edgeConfigs.keys {
            setEdgeRevealed(id, true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.pulseGeneration == generation else { return }
            for id in self.edgeConfigs.keys {
                guard let panel = self.panels[id] else { continue }
                if !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
                    self.setEdgeRevealed(id, false)
                }
            }
        }
    }

    private func positionEdge(id: String, panel: NSPanel, animated: Bool) {
        guard let config = edgeConfigs[id] else { return }

        // Reference frame: the parent window, or the screen for a
        // macOS-Dock-style screen-edge surface.
        let reference: NSRect
        let topInset: CGFloat
        if config.attach == "screen" {
            guard let screen = panel.screen ?? NSScreen.main else { return }
            reference = screen.visibleFrame
            topInset = 0
        } else {
            guard let parent = panel.parent else { return }
            reference = parent.frame
            topInset = 40
        }

        let width = CGFloat(config.width)
        let hidden = width - CGFloat(config.peek)
        let revealed = edgeRevealed.contains(id)

        // Collapsed window-attached surfaces park fully OUTSIDE the window:
        // overlapping the edge stole the window's resize zone.
        let x: CGFloat
        if config.edge == "right" {
            x = revealed
                ? reference.maxX - width
                : (config.attach == "screen" ? reference.maxX - CGFloat(config.peek) : reference.maxX + 1)
        } else {
            x = revealed
                ? reference.minX
                : (config.attach == "screen" ? reference.minX - hidden : reference.minX - width - 1)
        }

        let frame = NSRect(
            x: x, y: reference.minY,
            width: width, height: reference.height - topInset
        )
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func show(id: String, title: String, anchor: String, width: Double, tree: [String: Any]) {
        let root = AnyView(SurfaceRootView(surfaceId: id, title: title, node: tree))

        if let panel = panels[id], let hosting = hostings[id] {
            // Update in place: SwiftUI diffs the tree; replacing the view
            // caused stuck-state artifacts. Width: the owner's (resized or
            // remembered) wins, else content-fit; height grows to fit
            // content but never fights a taller owner-set frame.
            hosting.rootView = root
            let natural = hosting.fittingSize
            let w = Self.preferredWidth(requested: width, natural: natural.width,
                                        remembered: userSized.contains(id) ? panel.frame.width : nil)
            let h = max(natural.height, userSized.contains(id) ? panel.frame.height : 0)
            panel.setContentSize(NSSize(width: w, height: h))
            panel.invalidateShadow()
            return
        }

        let hosting = NSHostingView(rootView: root)
        let natural = hosting.fittingSize
        let remembered = Self.rememberedFrame(id)
        if remembered != nil { userSized.insert(id) }
        let fitted = Self.preferredWidth(requested: width, natural: natural.width, remembered: remembered?.width)
        let height = max(60, natural.height, remembered?.height ?? 0)

        // .resizable on a borderless panel = edge-drag resizing, no title bar.
        let panel = SurfacePanel(
            contentRect: NSRect(x: 0, y: 0, width: fitted, height: height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: 220, height: 60)
        panel.maxSize = NSSize(width: Self.maxPanelWidth, height: 1400)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        // Independent of the browser window, NOT a child of it (the owner
        // found the glued-together "one window" behaviour annoying): the
        // .floating level keeps panels above the main window whenever Bowser
        // is active, hidesOnDeactivate takes them away with the app and
        // brings them back with it, and fullScreenAuxiliary lets them show
        // over a fullscreen main window without being its child.
        // NOT hidesOnDeactivate: that made every panel vanish the moment the
        // owner glanced at another app. Instead the level follows activation
        // (observeActivation): floating while Bowser is active, normal — a
        // plain window in the stack — when it is not.
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        observeActivation()

        let effect = NSVisualEffectView(frame: panel.contentLayoutRect)
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        // Layer cornerRadius does NOT round the behind-window backdrop —
        // the system composites a square blur/shadow region behind the
        // clipped layer. maskImage masks the backdrop itself.
        effect.maskImage = Self.roundedMask(radius: 14)
        effect.autoresizingMask = [.width, .height]

        hosting.autoresizingMask = [.width, .height]
        hosting.frame = effect.bounds
        effect.addSubview(hosting)
        panel.contentView = effect

        if let remembered, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(remembered) }) {
            panel.setFrame(remembered, display: false)
        } else {
            position(panel, anchor: anchor)
        }
        panel.orderFront(nil)
        panel.invalidateShadow()
        panels[id] = panel
        hostings[id] = hosting
        rememberFrame(of: panel, id: id)
    }

    // MARK: - Windows remember themselves

    /// Content-fit width capped so a long hstack cannot run off the screen.
    nonisolated static let maxPanelWidth: CGFloat = 480

    /// Ids whose frame the owner set (resized/moved, or remembered): their
    /// width is never overridden by a re-render.
    private var userSized: Set<String> = []

    /// The width a panel gets: the owner's remembered/resized width wins;
    /// otherwise the larger of what the mod asked for and what the content
    /// needs, capped. Pure — tested.
    nonisolated static func preferredWidth(requested: CGFloat, natural: CGFloat, remembered: CGFloat?) -> CGFloat {
        if let remembered, remembered >= 220 { return min(remembered, maxPanelWidth) }
        return min(max(requested, natural.rounded(.up)), maxPanelWidth)
    }

    private static func frameKey(_ id: String) -> String { "BowserPanelFrame." + id }

    static func rememberedFrame(_ id: String) -> NSRect? {
        guard let text = UserDefaults.standard.string(forKey: frameKey(id)) else { return nil }
        let rect = NSRectFromString(text)
        return rect.width >= 220 && rect.height >= 40 ? rect : nil
    }

    /// Persist the frame whenever the owner moves or resizes the panel, so a
    /// re-show or a restart puts it back exactly where it was.
    private func rememberFrame(of panel: NSPanel, id: String) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            center.addObserver(forName: name, object: panel, queue: .main) { [weak self, weak panel] _ in
                MainActor.assumeIsolated {
                    guard let panel else { return }
                    self?.userSized.insert(id)
                    UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey(id))
                }
            }
        }
    }

    /// Focus follows the main window: re-front every live surface. Only
    /// WINDOW-attached edges are children of the browser window (they hug
    /// its edge) — re-adopt those when their parent was closed. Floating
    /// panels and screen-attached edges are independent windows: front
    /// them, never re-parent them. Any panel that drifted off every screen
    /// gets rescued back beside the parent (bowser-browser-gpi).
    func orderAllFront(parent: NSWindow) {
        for (id, panel) in panels where panel !== parent {
            let screenAttached = edgeConfigs[id]?.attach == "screen"
            let windowAttachedEdge = edgeConfigs[id] != nil && !screenAttached
            // Edges keep their hosting view in overlayHostings too — a
            // toolbar overlay is one WITHOUT an edge config. Treating the
            // dock as an overlay re-parented it into the focused window and
            // laid it out as a 1200x64 strip over the title bar.
            if overlayHostings[id] != nil, edgeConfigs[id] == nil {
                // The toolbar overlay rides the FOCUSED window too.
                if panel.parent !== parent {
                    panel.parent?.removeChildWindow(panel)
                    parent.addChildWindow(panel, ordered: .above)
                    positionOverlay(panel)
                }
                continue
            }
            if windowAttachedEdge {
                // The edge rides with the FOCUSED window: re-parent when
                // another window takes focus. Ordering a child window front
                // raises its parent's whole group — with the dock still
                // parented to the previous window, every focus change (and
                // every app reactivation) shoved that window back on top.
                if panel.parent !== parent {
                    panel.parent?.removeChildWindow(panel)
                    parent.addChildWindow(panel, ordered: .above)
                    positionEdge(id: id, panel: panel, animated: false)
                }
                continue // children are ordered with their parent; never orderFront them
            }
            if !screenAttached,
               !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
                panel.setFrameOrigin(Self.clamped(panel.frame.origin,
                                                  size: panel.frame.size,
                                                  in: parent.screen?.visibleFrame))
            }
            if panel.parent == nil { panel.orderFront(nil) }
        }
    }

    /// Keep a panel origin on the screen, with a small margin. Nil visible
    /// frame (headless) passes the origin through.
    static func clamped(_ origin: NSPoint, size: NSSize, in visible: NSRect?) -> NSPoint {
        guard let visible else { return origin }
        return NSPoint(
            x: min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8)),
            y: min(max(origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        )
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func position(_ panel: NSPanel, anchor: String) {
        guard let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            panel.center()
            return
        }
        let frame = main.frame
        let size = panel.frame.size
        let drop = 40 + CGFloat(panels.count) * (size.height + 20)
        // Anchors beside a fullscreen (or screen-hugging) window land past
        // the screen edge — clamp into the visible frame, overlapping the
        // window rather than vanishing (bowser-browser-gpi).
        let origin: NSPoint
        switch anchor {
        case "left_of_main":
            origin = NSPoint(x: frame.minX - size.width - 14, y: frame.maxY - size.height - drop)
        case "right_of_main":
            origin = NSPoint(x: frame.maxX + 14, y: frame.maxY - size.height - drop)
        default:
            panel.center()
            return
        }
        panel.setFrameOrigin(Self.clamped(origin, size: size, in: main.screen?.visibleFrame))
    }
}

/// Borderless panels refuse key status by default; allow it so text fields
/// in palettes can be edited (becomesKeyOnlyIfNeeded keeps buttons from
/// stealing focus).
private final class SurfacePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Cursor plumbing for proximity widgets (magnify_strip etc.)

/// Cursor position within an edge surface, in the hosting view's coordinate
/// space (nil = cursor outside). Widgets read it via @EnvironmentObject.
final class CursorModel: ObservableObject {
    @Published var point: CGPoint?
}

/// AppKit tracking host: .activeAlways tracking areas deliver mouseMoved
/// reliably even in never-key panels (the reason SwiftUI onHover was banned
/// here). Feeds CursorModel and drives the manager's reveal/collapse slide.
final class EdgeTrackingView: NSView {
    private let surfaceId: String
    private let cursor: CursorModel

    init(surfaceId: String, cursor: CursorModel) {
        self.surfaceId = surfaceId
        self.cursor = cursor
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
    }

    // Top-origin so cursor coordinates match SwiftUI's space directly.
    override var isFlipped: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Blank space between dock controls belongs to the dock as well.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func mouseEntered(with event: NSEvent) {
        SurfaceManager.shared.setEdgeRevealed(surfaceId, true)
    }

    override func mouseExited(with event: NSEvent) {
        cursor.point = nil
        SurfaceManager.shared.setEdgeRevealed(surfaceId, false)
    }

    override func mouseMoved(with event: NSEvent) {
        cursor.point = convert(event.locationInWindow, from: nil)
    }
}

// MARK: - Root chrome (title + tree)

struct SurfaceRootView: View {
    let surfaceId: String
    let title: String
    let node: [String: Any]

    /// The ✕ sends exactly what the View-menu entry sends: the panels mod
    /// then suppresses + closes it, so it STAYS closed (event-driven mods
    /// can't re-show it) and the menu checkmark follows. A local close
    /// alone would be undone by the owner's next Surface.show.
    nonisolated static func closeClickId(for surfaceId: String) -> String { "panel:\(surfaceId)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .kerning(1.1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(action: {
                    ChromeSurface.emit([
                        "op": "event", "event": "chrome_click",
                        "id": Self.closeClickId(for: surfaceId),
                    ])
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
        // Hairline drawn here (the old layer border was square-cornered).
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
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
            case "mono":
                // One-line log entry: what an agent said / which tool it called.
                return AnyView(
                    Text(value)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                )
            default:
                return AnyView(Text(value).font(.system(size: 13)))
            }
        case "button":
            return AnyView(SurfaceRow(node: node, emit: emit))
        case "row":
            return AnyView(SurfaceListRow(node: node, emit: emit, render: { self.render($0) }))
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
                    .foregroundStyle(.secondary)
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
                eventId: eventId,
                placeholder: node["placeholder"] as? String ?? "",
                initial: node["value"] as? String ?? "",
                emit: emit
            ))
        case "colorpicker":
            return AnyView(SurfaceColorPicker(
                eventId: node["event"] as? String ?? "color",
                initialHex: node["value"] as? String,
                label: node["label"] as? String ?? "",
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
        case "magnify_strip":
            return AnyView(MagnifyStripView(surfaceId: surfaceId, node: node, emit: emit))
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
                    .foregroundStyle(.red)
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
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 1)
                } else if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.12))
                }
            }
            .opacity(configuration.isPressed && active ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor
enum ImageCache {
    private static var cache: [String: NSImage] = [:]

    static func load(_ path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = image
        return image
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

    @EnvironmentObject var cursor: CursorModel

    // Dock bounce (bowser-browser-r0g): when the active item changes, the
    // newly active icon hops outward once. The stamp is the animation
    // trigger; inactive items are guarded to zero offset so losing
    // activation never twitches.
    @State private var bounceStamp = 0

    private var items: [[String: Any]] { node["items"] as? [[String: Any]] ?? [] }

    private var activeId: String? {
        items.first(where: { ($0["active"] as? Bool) == true })?["id"] as? String
    }
    private var baseSize: CGFloat { CGFloat(node["size"] as? Double ?? 28) }
    // Clamped: it's a scale MULTIPLIER (2.0 = double size), and a mod
    // passing pixels here (it happened) must not explode the layout.
    private var magnify: CGFloat { min(3.0, max(1.0, CGFloat(node["magnify"] as? Double ?? 1.9))) }
    private var eventId: String { node["event"] as? String ?? "select" }
    private let spacing: CGFloat = 8
    private let topPad: CGFloat = 12

    /// Vertical origin of the icon block: centered in the view, clamping
    /// back to top-aligned when the strip overflows (bowser-browser-2c8).
    /// The SAME value feeds layout and the magnification row centers so
    /// hover targets stay aligned.
    static func centeredTop(
        viewHeight: CGFloat, count: Int, size: CGFloat, spacing: CGFloat, minPad: CGFloat
    ) -> CGFloat {
        let content = max(0, CGFloat(count) * (size + spacing) - spacing)
        return max(minPad, (viewHeight - content) / 2)
    }

    private func scale(forRow index: Int, top: CGFloat) -> CGFloat {
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
                size: baseSize, spacing: spacing, minPad: topPad
            )
            VStack(spacing: spacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let s = scale(forRow: index, top: top)
                    let active = item["active"] as? Bool ?? false
                    Button(action: { emit(eventId, item["id"]) }) {
                        ZStack(alignment: .bottom) {
                            icon(for: item)
                                .frame(width: baseSize * s, height: baseSize * s)
                                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                            if active {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 4, height: 4)
                                    .offset(y: 5)
                            }
                        }
                        .frame(height: baseSize * s)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay {
                        if surfaceId == "edge_dock", let id = item["id"] as? String,
                           let webviewID = UInt64(id) {
                            TabAppDragTarget(webviewID: webviewID) { emit(eventId, item["id"]) }
                        }
                    }
                    .help(item["title"] as? String ?? "")
                    .animation(.easeOut(duration: 0.09), value: cursor.point)
                    // The hop: out fast, settle back springy. The left-edge
                    // dock bounces rightward, into the page.
                    .phaseAnimator([false, true], trigger: active ? bounceStamp : -1) { content, out in
                        content.offset(x: out && active ? 10 : 0)
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
    }

    @ViewBuilder
    private func icon(for item: [String: Any]) -> some View {
        // Keep profile identity as a small dot without outlining the artwork.
        let ring = Profile.color(hex: item["tint"] as? String)
        Group {
            if let path = item["path"] as? String, let image = ImageCache.load(path) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .scaledToFit()
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

/// Native ColorPicker. Emits "#rrggbb" 350ms after the last change, so a
/// drag across the wheel is one event and the brain can persist without
/// re-rendering (a rebuild mid-drag would close the popover).
private struct SurfaceColorPicker: View {
    let eventId: String
    let initialHex: String?
    let label: String
    let emit: (String, Any?) -> Void

    @State private var color: Color = .gray
    @State private var loaded = false
    @State private var pending: Task<Void, Never>?

    /// "#rrggbb" for a color, in sRGB. Pure — tested.
    nonisolated static func hex(_ nsColor: NSColor) -> String {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        func byte(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    var body: some View {
        ColorPicker(label, selection: $color, supportsOpacity: false)
            .font(.system(size: 12))
            .onAppear {
                if !loaded {
                    color = Color(nsColor: Profile.color(hex: initialHex) ?? .systemGray)
                    loaded = true
                }
            }
            .onChange(of: color) { _, newValue in
                guard loaded else { return }
                pending?.cancel()
                let hex = Self.hex(NSColor(newValue))
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    if !Task.isCancelled { emit(eventId, hex) }
                }
            }
    }
}

/// icon · title / subtitle · trailing controls. A subtitle stays one line;
/// trailing nodes are laid out by the same renderer (toggle, buttons, a
/// compact textfield).
private struct SurfaceListRow: View {
    let node: [String: Any]
    let emit: (String, Any?) -> Void
    let render: ([String: Any]) -> AnyView

    var body: some View {
        let trailing = node["trailing"] as? [[String: Any]] ?? []
        let content = HStack(alignment: .center, spacing: 10) {
            if let hex = node["swatch"] as? String, let color = Profile.color(hex: hex) {
                Circle().fill(Color(nsColor: color)).frame(width: 12, height: 12)
            } else if let path = node["path"] as? String, let image = ImageCache.load(path) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
            } else if let symbol = node["symbol"] as? String {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(node["title"] as? String ?? "").font(.system(size: 13)).lineLimit(1)
                if let subtitle = node["subtitle"] as? String, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            ForEach(Array(trailing.enumerated()), id: \.offset) { _, child in
                render(child)
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
            Rectangle().fill(.separator).frame(height: 0.5).opacity(0.6)
        }
    }
}

/// A macOS switch. Emits its new value on change (with payload, when given,
/// as {"on": bool, "payload": …} so one event id can serve a list).
private struct SurfaceToggle: View {
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
        Toggle(label, isOn: $on)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .onChange(of: on) { _, value in
                if let payload {
                    emit(eventId, ["on": value, "payload": payload])
                } else {
                    emit(eventId, value)
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

/// Test seam for SurfaceColorPicker.hex (the view itself is file-private).
enum SurfaceColorPickerHexBridge {
    nonisolated static func hex(_ color: NSColor) -> String { SurfaceColorPicker.hex(color) }
}
